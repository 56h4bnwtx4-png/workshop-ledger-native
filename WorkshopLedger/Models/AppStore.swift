import Foundation
import Combine

enum CloudSyncState: Equatable {
    case localOnly
    case pending
    case syncing
    case synced
    case failed(String)
}

struct CloudAccountSummary: Equatable {
    let accountId: String
    let username: String
    let displayName: String
    let baseURL: URL
    let expiresAt: Date?
    let scope: String
    let canWrite: Bool
    let status: String
}

struct CloudDeviceSummary: Equatable {
    let id: String
    let displayName: String
    let slot: String
    let platform: String
    let leaseGeneration: Int
}

struct CloudRestoreResult: Equatable {
    let mergedBillCount: Int
    let revision: Int
    let sourceLabel: String
}

@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var customers: [Customer] = []
    @Published private(set) var employees: [Employee] = []
    @Published private(set) var bills: [Bill] = []
    @Published private(set) var settlementBatches: [SettlementBatch] = []
    @Published private(set) var drafts: [DraftSummary] = []
    @Published var lastError: String?

    @Published private(set) var cloudState: CloudSyncState = .localOnly
    @Published private(set) var cloudSession: CloudAccountSummary?
    @Published private(set) var boundDevice: CloudDeviceSummary?
    @Published private(set) var mustChangePassword = false
    @Published private(set) var accountCanWrite = true
    @Published private(set) var accountStatus = "active"
    @Published private(set) var hasPendingCloudChanges = false
    @Published private(set) var pendingBillDates: Set<String> = []
    @Published private(set) var lastCloudSyncAt: Date?
    @Published private(set) var lastCloudSnapshotName: String?
    @Published private(set) var cloudRevision: Int = 0
    @Published private(set) var lastCloudError: String?

    private var database: Database?
    private let remoteLedger: HTTPRemoteLedgerService
    private let defaults: UserDefaults
    private var activeSession: ActiveCloudSession?
    private var retryTask: Task<Void, Never>?
    private var syncInFlight = false
    private var cloudChangeGeneration = 0
    private var didStartCloud = false

    private let baseURLKey = "workshopLedger.cloud.baseURL.v1"
    private let usernameKey = "workshopLedger.cloud.username.v1"
    private let accountIdKey = "workshopLedger.cloud.accountId.v2"
    private let displayNameKey = "workshopLedger.cloud.displayName.v2"
    private let deviceIdKey = "workshopLedger.cloud.deviceId.v2"
    private let deviceNameKey = "workshopLedger.cloud.deviceName.v2"
    private let deviceLeaseKey = "workshopLedger.cloud.deviceLease.v2"
    private let expiresAtKey = "workshopLedger.cloud.expiresAt.v1"
    private let mustChangeKey = "workshopLedger.cloud.mustChangePassword.v2"
    private let canWriteKey = "workshopLedger.cloud.canWrite.v2"
    private let accountStatusKey = "workshopLedger.cloud.accountStatus.v2"
    private let pendingKey = "workshopLedger.cloud.pending.v1"
    private let pendingDatesKey = "workshopLedger.cloud.pendingBillDates.v1"
    private let lastSyncKey = "workshopLedger.cloud.lastSyncAt.v1"
    private let snapshotNameKey = "workshopLedger.cloud.lastSnapshotName.v1"
    private let revisionKey = "workshopLedger.cloud.revision.v1"
    private let tokenAccount = "session-token"
    private let stableDeviceIdAccount = "stable-device-id"

    init(
        remoteLedger: HTTPRemoteLedgerService = HTTPRemoteLedgerService(),
        defaults: UserDefaults = .standard
    ) {
        self.remoteLedger = remoteLedger
        self.defaults = defaults
        KeychainStore.delete("account-password")
        restoreLocalCloudMetadata()
        restoreStoredSession()
    }

    var savedUsername: String {
        defaults.string(forKey: usernameKey) ?? ""
    }

    var hasSavedPassword: Bool { false }

    var isCloudLoggedIn: Bool {
        activeSession != nil
    }

    var isReadyForApp: Bool {
        activeSession != nil && !mustChangePassword
    }

    var isReadOnly: Bool {
        isCloudLoggedIn && !accountCanWrite
    }

    var accountDisplayName: String {
        cloudSession?.displayName ?? "车间账本"
    }
    var cloudBadgeText: String {
        if activeSession == nil {
            return hasPendingCloudChanges ? "待云端备份" : "本地账本"
        }
        switch cloudState {
        case .syncing: return "正在同步云端"
        case .synced: return "云端已备份"
        case .pending, .failed: return "待云端备份"
        case .localOnly: return "本地账本"
        }
    }

    var cloudStatusText: String {
        if activeSession == nil {
            return hasPendingCloudChanges ? "有数据等待登录后备份" : "尚未登录云端账号"
        }
        switch cloudState {
        case .localOnly:
            return "尚未登录云端账号"
        case .pending:
            return "本机有改动，等待上传"
        case .syncing:
            return "正在上传正式账单与档案"
        case .synced:
            if let lastCloudSyncAt {
                return "已同步 · \(formatCloudTime(lastCloudSyncAt))"
            }
            return "云端数据已同步"
        case .failed(let message):
            return "同步失败 · \(message)"
        }
    }

    func reloadAll() {
        guard let database else { return }
        do {
            customers = try database.loadCustomers()
            employees = try database.loadEmployees()
            bills = try database.loadBills()
            settlementBatches = try database.loadSettlementBatches()
            drafts = try database.loadDraftSummaries()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func bill(on date: Date) -> Bill? {
        let key = DateKey.string(from: date)
        return bills.first { DateKey.string(from: $0.date) == key }
    }

    func draft(on date: Date) -> DraftSummary? {
        let key = DateKey.string(from: date)
        return drafts.first { DateKey.string(from: $0.date) == key }
    }

    func loadRows(for date: Date) -> (rows: [EntryRow], source: EntrySource) {
        guard let database else { return ([EntryRow.empty()], .new) }
        do {
            if let draftRows = try database.loadDraft(date: date), !draftRows.isEmpty {
                return (draftRows, .draft)
            }
            if let existing = bill(on: date), !existing.items.isEmpty {
                let rows = existing.items.map {
                    EntryRow(
                        id: UUID(),
                        customer: $0.customer,
                        employee: $0.employee,
                        model: $0.model,
                        quantity: String($0.quantity),
                        colorCount: $0.colorCount,
                        existingItemID: $0.id,
                        storedUnitPriceCents: $0.unitPriceCents,
                        settlementBatchID: $0.settlementBatchID
                    )
                }
                return (rows, .bill)
            }
        } catch {
            lastError = error.localizedDescription
        }
        return ([EntryRow.empty(customer: customers.first?.name ?? "", employee: employees.first?.name ?? "")], .new)
    }

    func saveDraft(date: Date, rows: [EntryRow]) {
        guard accountCanWrite else { lastError = "账号当前为只读状态，不能保存草稿。"; return }
        guard let database else { return }
        do {
            try database.saveDraft(date: date, rows: rows)
            drafts = try database.loadDraftSummaries()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteDraft(date: Date) {
        guard accountCanWrite else { lastError = "账号当前为只读状态，不能修改草稿。"; return }
        guard let database else { return }
        do {
            try database.deleteDraft(date: date)
            drafts = try database.loadDraftSummaries()
        } catch {
            lastError = error.localizedDescription
        }
    }

    @discardableResult
    func submitBill(date: Date, rows: [EntryRow]) throws -> Bill {
        try ensureWritable()
        guard let database else {
            throw DatabaseError.openFailed("数据库未打开")
        }
        let bill = try database.saveBill(date: date, rows: rows)
        customers = try database.loadCustomers()
        employees = try database.loadEmployees()
        bills = try database.loadBills()
        settlementBatches = try database.loadSettlementBatches()
        drafts = try database.loadDraftSummaries()
        markCloudDirty(billDate: date)
        return bill
    }

    func addCustomer(name: String, unitPriceCents: Int64? = nil) throws {
        try ensureWritable()
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        _ = try database.addCustomer(name: name, unitPriceCents: unitPriceCents)
        customers = try database.loadCustomers()
        markCloudDirty()
    }

    func updateCustomer(_ customer: Customer, name: String, unitPriceCents: Int64?) throws {
        try ensureWritable()
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        let shouldBackfill = customer.unitPriceCents == nil && unitPriceCents != nil
        try database.updateCustomer(
            id: customer.id,
            name: name,
            unitPriceCents: unitPriceCents,
            backfillHistoricalPrices: shouldBackfill
        )
        customers = try database.loadCustomers()
        bills = try database.loadBills()
        settlementBatches = try database.loadSettlementBatches()
        markCloudDirty()
    }

    func unitPriceCents(forCustomer name: String) -> Int64? {
        customers.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?.unitPriceCents
    }

    func settlementBatch(id: Int64?) -> SettlementBatch? {
        guard let id else { return nil }
        return settlementBatches.first { $0.id == id }
    }

    @discardableResult
    func createSettlementBatch(
        itemIDs: [Int64],
        settlementDate: Date,
        actualAmountCents: Int64,
        note: String
    ) throws -> SettlementBatch {
        try ensureWritable()
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        let batch = try database.createSettlementBatch(
            itemIDs: itemIDs,
            settlementDate: settlementDate,
            actualAmountCents: actualAmountCents,
            note: note
        )
        bills = try database.loadBills()
        settlementBatches = try database.loadSettlementBatches()
        markCloudDirty()
        return batch
    }

    func revokeSettlementBatch(_ batch: SettlementBatch) throws {
        try ensureWritable()
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        try database.revokeSettlementBatch(id: batch.id)
        bills = try database.loadBills()
        settlementBatches = try database.loadSettlementBatches()
        markCloudDirty()
    }

    func deleteCustomer(_ customer: Customer) throws {
        try ensureWritable()
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        try database.deleteCustomer(id: customer.id)
        customers = try database.loadCustomers()
        markCloudDirty()
    }

    func addEmployee(name: String) throws {
        try ensureWritable()
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        _ = try database.addEmployee(name: name)
        employees = try database.loadEmployees()
        markCloudDirty()
    }

    func updateEmployee(_ employee: Employee, name: String) throws {
        try ensureWritable()
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        try database.updateEmployee(id: employee.id, name: name)
        employees = try database.loadEmployees()
        markCloudDirty()
    }

    func deleteEmployee(_ employee: Employee) throws {
        try ensureWritable()
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        try database.deleteEmployee(id: employee.id)
        employees = try database.loadEmployees()
        markCloudDirty()
    }

    func queryRecords(
        startDate: Date,
        endDate: Date,
        employee: String,
        customer: String,
        colorCount: Int?,
        modelText: String
    ) -> [QueryRecord] {
        let start = DateKey.startOfDay(startDate)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: DateKey.startOfDay(endDate)) ?? endDate
        let search = modelText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return bills
            .filter { $0.date >= start && $0.date < end }
            .flatMap { bill in
                bill.items.compactMap { item in
                    guard employee.isEmpty || item.employee == employee else { return nil }
                    guard customer.isEmpty || item.customer == customer else { return nil }
                    guard colorCount == nil || item.colorCount == colorCount else { return nil }
                    guard search.isEmpty || item.model.lowercased().contains(search) else { return nil }
                    return QueryRecord(
                        id: "\(bill.id)-\(item.id)",
                        billID: bill.id,
                        itemID: item.id,
                        date: bill.date,
                        employee: item.employee,
                        customer: item.customer,
                        model: item.model,
                        quantity: item.quantity,
                        colorCount: item.colorCount,
                        workload: item.workload
                    )
                }
            }
            .sorted {
                if $0.date == $1.date { return $0.id > $1.id }
                return $0.date > $1.date
            }
    }

    var allCustomerNames: [String] {
        uniqueSorted(customers.map(\.name) + bills.flatMap { $0.items.map(\.customer) })
    }

    var allEmployeeNames: [String] {
        uniqueSorted(employees.map(\.name) + bills.flatMap { $0.items.map(\.employee) })
    }

    var allModelNames: [String] {
        uniqueSorted(bills.flatMap { $0.items.map(\.model) })
    }

    func draftRows(on date: Date) -> [EntryRow] {
        guard let database else { return [] }
        return (try? database.loadDraft(date: date)) ?? []
    }

    func createDatabaseBackup() throws -> URL {
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        return try database.createBackupCopy()
    }

    func isBillPending(_ date: Date) -> Bool {
        pendingBillDates.contains(DateKey.string(from: date))
    }

}


extension AppStore {
    private struct ActiveCloudSession {
        let accountId: String
        let username: String
        let displayName: String
        let baseURL: URL
        let token: String
        let expiresAt: Date?
        let scope: String
        let deviceId: String
        let deviceName: String
        let leaseGeneration: Int
        let status: String
        let canWrite: Bool
    }

    func login(username: String, password: String) async throws {
        let normalizedURL = URL(string: CloudDefaults.baseURL)!
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty else {
            throw RemoteLedgerError.server(status: 400, message: "请输入账号。", code: "username_required")
        }
        guard !password.isEmpty else {
            throw RemoteLedgerError.server(status: 400, message: "请输入密码。", code: "password_required")
        }
        let deviceId = stableDeviceId()
        let deviceName = storedDeviceName()
        let response = try await remoteLedger.login(
            baseURL: normalizedURL,
            username: normalizedUsername,
            password: password,
            clientType: CloudDefaults.clientType,
            deviceId: deviceId,
            deviceName: deviceName
        )
        let tokenExpiresAt = CloudDate.parse(response.expiresAt)
        let session = ActiveCloudSession(
            accountId: response.account.id,
            username: response.account.loginName,
            displayName: response.account.displayName,
            baseURL: normalizedURL,
            token: response.token,
            expiresAt: tokenExpiresAt,
            scope: response.scope,
            deviceId: response.device.id,
            deviceName: response.device.displayName,
            leaseGeneration: response.device.leaseGeneration,
            status: response.access.effectiveStatus,
            canWrite: response.access.canWrite && response.scope == "write"
        )

        let previousAccountId = defaults.string(forKey: accountIdKey)
        if let previousAccountId, previousAccountId != response.account.id {
            hasPendingCloudChanges = false
            pendingBillDates.removeAll()
            persistPendingState()
            lastCloudSyncAt = nil
            lastCloudSnapshotName = nil
            cloudRevision = 0
        }

        do {
            database = try Database(accountId: response.account.id)
            reloadAll()
            activeSession = session
            apply(account: response.account, device: response.device, access: response.access)
            mustChangePassword = response.mustChangePassword
            KeychainStore.set(response.token, for: tokenAccount)
            persistSessionMetadata()
            lastCloudError = nil
            cloudState = hasPendingCloudChanges ? .pending : .synced
            if response.mustChangePassword {
                return
            }
            try await finishAuthenticatedLogin()
        } catch {
            if activeSession?.token == response.token {
                await remoteLedger.logout(baseURL: normalizedURL, token: response.token)
            }
            clearLocalSession(deleteDatabase: false)
            throw error
        }
    }

    func completeRequiredPasswordChange(currentPassword: String, newPassword: String) async throws {
        guard let session = activeSession, mustChangePassword else {
            throw RemoteLedgerError.unauthorized
        }
        let response = try await remoteLedger.changePassword(
            baseURL: session.baseURL,
            token: session.token,
            currentPassword: currentPassword,
            newPassword: newPassword
        )
        mustChangePassword = response.mustChangePassword
        apply(account: response.account, device: nil, access: response.access)
        persistSessionMetadata()
        guard !mustChangePassword else { return }
        try await finishAuthenticatedLogin()
    }

    func changePassword(currentPassword: String, newPassword: String) async throws {
        guard let session = activeSession, !mustChangePassword else {
            throw RemoteLedgerError.unauthorized
        }
        let response = try await remoteLedger.changePassword(
            baseURL: session.baseURL,
            token: session.token,
            currentPassword: currentPassword,
            newPassword: newPassword
        )
        mustChangePassword = response.mustChangePassword
        apply(account: response.account, device: nil, access: response.access)
        persistSessionMetadata()
    }

    @discardableResult
    func logout(force: Bool = false) async -> Bool {
        if hasPendingCloudChanges && !force {
            lastCloudError = "还有正式账单没有备份成功。请先同步，或确认放弃本机待同步数据后再退出。"
            return false
        }
        retryTask?.cancel()
        retryTask = nil
        let session = activeSession
        let accountId = session?.accountId
        if let session {
            await remoteLedger.logout(baseURL: session.baseURL, token: session.token)
        }
        clearLocalSession(deleteDatabase: true, accountId: accountId)
        return true
    }

    func unbindCurrentDevice() async throws {
        guard let session = activeSession else {
            throw RemoteLedgerError.unauthorized
        }
        if hasPendingCloudChanges {
            throw RemoteLedgerError.server(
                status: 409,
                message: "本机还有未备份的正式账单，请先同步后再解绑设备。",
                code: "pending_changes"
            )
        }
        try await remoteLedger.unbindDevice(
            baseURL: session.baseURL,
            token: session.token,
            deviceId: session.deviceId
        )
        clearLocalSession(deleteDatabase: true, accountId: session.accountId)
    }

    func listCloudDevices() async throws -> [RemoteDeviceRecord] {
        let session = try await validSession()
        do {
            return try await remoteLedger.listDevices(baseURL: session.baseURL, token: session.token)
        } catch RemoteLedgerError.unauthorized {
            invalidateSession(reason: "设备绑定已失效，请重新登录。")
            throw RemoteLedgerError.unauthorized
        }
    }
    func applicationBecameActive() async {
        guard isReadyForApp else {
            if !isCloudLoggedIn { cloudState = .localOnly }
            return
        }
        if !didStartCloud {
            didStartCloud = true
        }
        if hasPendingCloudChanges {
            _ = await syncNow(force: true)
        } else {
            await refreshCloudStatus()
        }
    }

    @discardableResult
    func syncNow(force: Bool = false) async -> Bool {
        guard !mustChangePassword else {
            lastCloudError = "请先修改临时密码。"
            return false
        }
        guard accountCanWrite else {
            lastCloudError = "账号当前为只读状态，不能上传数据。"
            cloudState = .failed(lastCloudError ?? "只读状态")
            return false
        }
        guard force || hasPendingCloudChanges else {
            await refreshCloudStatus()
            if case .failed = cloudState { return false }
            return true
        }
        guard activeSession != nil else {
            cloudState = .localOnly
            return false
        }
        guard let data = buildRemoteWorkshopData() else {
            lastCloudError = "本机数据库未打开。"
            cloudState = .failed(lastCloudError ?? "本机数据库未打开")
            return false
        }
        guard !syncInFlight else { return false }
        retryTask?.cancel()
        retryTask = nil
        let generation = cloudChangeGeneration
        syncInFlight = true
        defer { syncInFlight = false }
        cloudState = .syncing
        lastCloudError = nil
        do {
            let saved = try await authorizedSave(data)
            cloudRevision = saved.revision
            lastCloudSyncAt = Date()
            lastCloudSnapshotName = saved.latestSnapshot?.fileName ?? lastCloudSnapshotName
            persistCloudMetadata()
            if generation == cloudChangeGeneration {
                markCloudClean()
                cloudState = .synced
            } else {
                cloudState = .pending
                scheduleRetry(after: 2)
            }
            return true
        } catch {
            let message = friendlyCloudError(error)
            lastCloudError = message
            cloudState = .failed(message)
            if activeSession != nil && accountCanWrite {
                scheduleRetry(after: 30)
            }
            return false
        }
    }

    func refreshCloudStatus() async {
        guard activeSession != nil, !mustChangePassword else {
            cloudState = .localOnly
            return
        }
        do {
            let remote = try await authorizedWorkspace()
            applyRemoteWorkspace(remote)
            cloudRevision = remote.revision
            lastCloudSnapshotName = remote.latestSnapshot?.fileName ?? lastCloudSnapshotName
            if !hasPendingCloudChanges {
                cloudState = .synced
            }
            persistCloudMetadata()
        } catch {
            let message = friendlyCloudError(error)
            lastCloudError = message
            cloudState = .failed(message)
        }
    }

    func restoreLatestWorkspace() async throws -> CloudRestoreResult {
        let hadPendingCloudChanges = hasPendingCloudChanges
        let remote = try await authorizedWorkspace()
        applyRemoteWorkspace(remote)
        let merged = try merge(remote.data)
        cloudRevision = remote.revision
        lastCloudSnapshotName = remote.latestSnapshot?.fileName ?? lastCloudSnapshotName
        persistCloudMetadata()
        if hadPendingCloudChanges {
            cloudState = .pending
            scheduleRetry(after: 2)
        } else {
            markCloudClean()
            cloudState = .synced
        }
        return CloudRestoreResult(
            mergedBillCount: merged,
            revision: remote.revision,
            sourceLabel: remote.latestSnapshot?.fileName ?? "服务器当前数据"
        )
    }

    func listCloudSnapshots() async throws -> [RemoteSnapshotRecord] {
        let snapshots = try await authorizedSnapshots()
        if !snapshots.isEmpty {
            lastCloudSnapshotName = snapshots[0].fileName
            persistCloudMetadata()
        }
        return snapshots
    }

    func restoreSnapshot(_ snapshot: RemoteSnapshotRecord) async throws -> CloudRestoreResult {
        let hadPendingCloudChanges = hasPendingCloudChanges
        let envelope = try await authorizedSnapshot(id: snapshot.id)
        guard envelope.accountId == nil || envelope.accountId == activeSession?.accountId else {
            throw RemoteLedgerError.server(status: 409, message: "该快照不属于当前账号。", code: "snapshot_account_mismatch")
        }
        let merged = try merge(envelope.data)
        cloudRevision = envelope.revision
        lastCloudSnapshotName = snapshot.fileName
        persistCloudMetadata()
        if hadPendingCloudChanges {
            cloudState = .pending
            scheduleRetry(after: 2)
        } else {
            markCloudClean()
            cloudState = .synced
        }
        return CloudRestoreResult(
            mergedBillCount: merged,
            revision: envelope.revision,
            sourceLabel: snapshot.fileName
        )
    }
    private func finishAuthenticatedLogin() async throws {
        guard !mustChangePassword else { return }
        let hadPendingCloudChanges = hasPendingCloudChanges
        let remote = try await authorizedWorkspace()
        applyRemoteWorkspace(remote)
        cloudRevision = remote.revision
        lastCloudSnapshotName = remote.latestSnapshot?.fileName ?? lastCloudSnapshotName

        let remoteHasData = remote.revision > 0 &&
            (!remote.data.bills.isEmpty || !remote.data.customers.isEmpty || !remote.data.employees.isEmpty)
        if remoteHasData {
            _ = try merge(remote.data)
        }

        let localHasData = !customers.isEmpty || !employees.isEmpty || !bills.isEmpty
        if hadPendingCloudChanges || (remote.revision == 0 && localHasData) {
            if !hadPendingCloudChanges {
                markCloudDirty()
            }
            _ = await syncNow(force: true)
        } else {
            markCloudClean()
            cloudState = .synced
        }
        lastCloudSyncAt = lastCloudSyncAt ?? Date()
        persistCloudMetadata()
        didStartCloud = true
    }

    private func validSession() async throws -> ActiveCloudSession {
        guard let activeSession else {
            throw RemoteLedgerError.unauthorized
        }
        if normalizedBaseURLString(activeSession.baseURL.absoluteString) != CloudDefaults.baseURL {
            invalidateSession(reason: "服务器地址已更新，请重新登录。")
            throw RemoteLedgerError.unauthorized
        }
        if let expiresAt = activeSession.expiresAt, expiresAt <= Date() {
            invalidateSession(reason: "登录已过期，请重新输入账号密码。")
            throw RemoteLedgerError.unauthorized
        }
        return activeSession
    }

    private func authorizedWorkspace() async throws -> RemoteWorkspaceResponse {
        let session = try await validSession()
        do {
            let remote = try await remoteLedger.fetchWorkspace(baseURL: session.baseURL, token: session.token)
            return remote
        } catch RemoteLedgerError.unauthorized {
            invalidateSession(reason: "登录已失效或设备已被解绑，请重新登录。")
            throw RemoteLedgerError.unauthorized
        }
    }

    private func authorizedSave(_ data: RemoteWorkshopData) async throws -> RemoteSaveResponse {
        let session = try await validSession()
        do {
            return try await remoteLedger.saveWorkspace(baseURL: session.baseURL, token: session.token, data: data)
        } catch RemoteLedgerError.unauthorized {
            invalidateSession(reason: "登录已失效或设备已被解绑，请重新登录。")
            throw RemoteLedgerError.unauthorized
        }
    }

    private func authorizedSnapshots() async throws -> [RemoteSnapshotRecord] {
        let session = try await validSession()
        do {
            return try await remoteLedger.listSnapshots(baseURL: session.baseURL, token: session.token)
        } catch RemoteLedgerError.unauthorized {
            invalidateSession(reason: "登录已失效或设备已被解绑，请重新登录。")
            throw RemoteLedgerError.unauthorized
        }
    }

    private func authorizedSnapshot(id: Int) async throws -> RemoteSnapshotEnvelope {
        let session = try await validSession()
        do {
            return try await remoteLedger.fetchSnapshot(baseURL: session.baseURL, token: session.token, id: id)
        } catch RemoteLedgerError.unauthorized {
            invalidateSession(reason: "登录已失效或设备已被解绑，请重新登录。")
            throw RemoteLedgerError.unauthorized
        }
    }

    private func apply(account: RemoteAccountRecord, device: RemoteDeviceRecord?, access: RemoteAccessRecord) {
        let currentTokenExpiry = activeSession?.expiresAt
        let scope = access.canWrite && activeSession?.scope == "write" ? "write" : "read"
        let currentDeviceId = device?.id ?? activeSession?.deviceId ?? stableDeviceId()
        let currentDeviceName = device?.displayName ?? activeSession?.deviceName ?? storedDeviceName()
        activeSession = ActiveCloudSession(
            accountId: account.id,
            username: account.loginName,
            displayName: account.displayName,
            baseURL: URL(string: CloudDefaults.baseURL)!,
            token: activeSession?.token ?? KeychainStore.get(tokenAccount) ?? "",
            expiresAt: currentTokenExpiry,
            scope: scope,
            deviceId: currentDeviceId,
            deviceName: currentDeviceName,
            leaseGeneration: device?.leaseGeneration ?? activeSession?.leaseGeneration ?? 1,
            status: access.effectiveStatus,
            canWrite: access.canWrite && scope == "write"
        )
        accountCanWrite = activeSession?.canWrite ?? false
        accountStatus = access.effectiveStatus
        mustChangePassword = account.mustChangePassword
        if let activeSession {
            cloudSession = summary(for: activeSession)
        }
        if let device {
            boundDevice = CloudDeviceSummary(
                id: device.id,
                displayName: device.displayName,
                slot: device.slot,
                platform: device.platform,
                leaseGeneration: device.leaseGeneration
            )
            defaults.set(device.displayName, forKey: deviceNameKey)
            defaults.set(device.leaseGeneration, forKey: deviceLeaseKey)
        }
    }

    private func applyRemoteWorkspace(_ remote: RemoteWorkspaceResponse) {
        if let account = remote.account, let access = remote.access {
            apply(account: account, device: remote.device, access: access)
        } else if let access = remote.access {
            accountCanWrite = access.canWrite && activeSession?.scope == "write"
            accountStatus = access.effectiveStatus
            if var session = activeSession {
                session = ActiveCloudSession(
                    accountId: session.accountId,
                    username: session.username,
                    displayName: session.displayName,
                    baseURL: session.baseURL,
                    token: session.token,
                    expiresAt: session.expiresAt,
                    scope: session.scope,
                    deviceId: session.deviceId,
                    deviceName: session.deviceName,
                    leaseGeneration: session.leaseGeneration,
                    status: access.effectiveStatus,
                    canWrite: access.canWrite && session.scope == "write"
                )
                activeSession = session
                cloudSession = summary(for: session)
            }
        }
        persistSessionMetadata()
    }

    private func summary(for session: ActiveCloudSession) -> CloudAccountSummary {
        CloudAccountSummary(
            accountId: session.accountId,
            username: session.username,
            displayName: session.displayName,
            baseURL: session.baseURL,
            expiresAt: session.expiresAt,
            scope: session.scope,
            canWrite: session.canWrite,
            status: session.status
        )
    }

    private func restoreStoredSession() {
        let fixedBaseURLString = CloudDefaults.baseURL
        let storedToken = KeychainStore.get(tokenAccount)
        let storedBaseURLString = defaults.string(forKey: baseURLKey)
        if let storedToken, !storedToken.isEmpty,
           normalizedBaseURLString(storedBaseURLString) != fixedBaseURLString {
            KeychainStore.delete(tokenAccount)
            clearSessionMetadata()
            defaults.set(fixedBaseURLString, forKey: baseURLKey)
            lastError = "服务器地址已更新，请重新登录。"
            return
        }
        defaults.set(fixedBaseURLString, forKey: baseURLKey)

        guard let token = storedToken, !token.isEmpty,
              let accountId = defaults.string(forKey: accountIdKey), !accountId.isEmpty,
              let username = defaults.string(forKey: usernameKey), !username.isEmpty else {
            return
        }
        let expiresAtValue = defaults.double(forKey: expiresAtKey)
        let expiresAt = expiresAtValue > 0 ? Date(timeIntervalSince1970: expiresAtValue) : nil
        if let expiresAt, expiresAt <= Date() {
            KeychainStore.delete(tokenAccount)
            return
        }
        do {
            database = try Database(accountId: accountId)
            let canWrite = defaults.bool(forKey: canWriteKey)
            let session = ActiveCloudSession(
                accountId: accountId,
                username: username,
                displayName: defaults.string(forKey: displayNameKey) ?? username,
                baseURL: URL(string: fixedBaseURLString)!,
                token: token,
                expiresAt: expiresAt,
                scope: canWrite ? "write" : "read",
                deviceId: KeychainStore.get(stableDeviceIdAccount) ?? "",
                deviceName: defaults.string(forKey: deviceNameKey) ?? storedDeviceName(),
                leaseGeneration: defaults.integer(forKey: deviceLeaseKey),
                status: defaults.string(forKey: accountStatusKey) ?? "active",
                canWrite: canWrite
            )
            activeSession = session
            cloudSession = summary(for: session)
            mustChangePassword = defaults.bool(forKey: mustChangeKey)
            accountCanWrite = canWrite
            accountStatus = session.status
            if let deviceId = KeychainStore.get(stableDeviceIdAccount) {
                boundDevice = CloudDeviceSummary(
                    id: deviceId,
                    displayName: session.deviceName,
                    slot: "writer",
                    platform: CloudDefaults.clientType,
                    leaseGeneration: session.leaseGeneration
                )
            }
            reloadAll()
            cloudState = hasPendingCloudChanges ? .pending : .synced
        } catch {
            lastError = error.localizedDescription
            invalidateSession(reason: "本机数据库无法打开：\(error.localizedDescription)")
        }
    }

    private func persistSessionMetadata() {
        guard let session = activeSession else { return }
        defaults.set(CloudDefaults.baseURL, forKey: baseURLKey)
        defaults.set(session.username, forKey: usernameKey)
        defaults.set(session.accountId, forKey: accountIdKey)
        defaults.set(session.displayName, forKey: displayNameKey)
        defaults.set(session.deviceName, forKey: deviceNameKey)
        defaults.set(session.leaseGeneration, forKey: deviceLeaseKey)
        defaults.set(session.status, forKey: accountStatusKey)
        defaults.set(session.canWrite, forKey: canWriteKey)
        defaults.set(mustChangePassword, forKey: mustChangeKey)
        if let expiresAt = session.expiresAt {
            defaults.set(expiresAt.timeIntervalSince1970, forKey: expiresAtKey)
        }
    }

    private func clearSessionMetadata() {
        KeychainStore.delete(tokenAccount)
        defaults.removeObject(forKey: accountIdKey)
        defaults.removeObject(forKey: displayNameKey)
        defaults.removeObject(forKey: expiresAtKey)
        defaults.removeObject(forKey: mustChangeKey)
        defaults.removeObject(forKey: canWriteKey)
        defaults.removeObject(forKey: accountStatusKey)
    }

    private func clearLocalSession(deleteDatabase: Bool, accountId: String? = nil) {
        retryTask?.cancel()
        retryTask = nil
        let targetAccountId = accountId ?? activeSession?.accountId ?? defaults.string(forKey: accountIdKey)
        activeSession = nil
        cloudSession = nil
        boundDevice = nil
        mustChangePassword = false
        accountCanWrite = false
        accountStatus = "active"
        clearSessionMetadata()
        hasPendingCloudChanges = false
        pendingBillDates.removeAll()
        persistPendingState()
        lastCloudSyncAt = nil
        lastCloudSnapshotName = nil
        cloudRevision = 0
        lastCloudError = nil
        cloudState = .localOnly
        database = nil
        customers = []
        employees = []
        bills = []
        drafts = []
        defaults.removeObject(forKey: snapshotNameKey)
        defaults.removeObject(forKey: revisionKey)
        defaults.removeObject(forKey: lastSyncKey)
        if deleteDatabase, let targetAccountId {
            try? Database.deleteAccountDatabase(accountId: targetAccountId)
        }
    }

    private func invalidateSession(reason: String) {
        retryTask?.cancel()
        retryTask = nil
        activeSession = nil
        cloudSession = nil
        boundDevice = nil
        mustChangePassword = false
        accountCanWrite = false
        accountStatus = "active"
        KeychainStore.delete(tokenAccount)
        defaults.removeObject(forKey: accountIdKey)
        defaults.removeObject(forKey: displayNameKey)
        defaults.removeObject(forKey: expiresAtKey)
        defaults.removeObject(forKey: mustChangeKey)
        defaults.removeObject(forKey: canWriteKey)
        cloudState = .localOnly
        lastCloudError = reason
        lastError = reason
    }
    private func ensureWritable() throws {
        if mustChangePassword {
            throw RemoteLedgerError.server(status: 428, message: "请先修改临时密码。", code: "password_change_required")
        }
        guard accountCanWrite else {
            throw RemoteLedgerError.server(status: 403, message: "账号当前为只读状态，不能修改账目。", code: "read_only")
        }
    }

    private func normalizedBaseURLString(_ value: String?) -> String {
        var text = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }

    private func stableDeviceId() -> String {
        if let existing = KeychainStore.get(stableDeviceIdAccount), !existing.isEmpty {
            return existing
        }
        let created = "ios-\(UUID().uuidString)"
        KeychainStore.set(created, for: stableDeviceIdAccount)
        return created
    }

    private func storedDeviceName() -> String {
        let value = defaults.string(forKey: deviceNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "车间 iPad" : value
    }

    private func buildRemoteWorkshopData() -> RemoteWorkshopData? {
        guard database != nil else { return nil }
        let remoteCustomers = customers.map {
            RemoteDirectoryRecord(
                name: $0.name,
                unitPriceCents: $0.unitPriceCents,
                createdAt: CloudDate.isoString($0.createdAt),
                updatedAt: CloudDate.isoString($0.updatedAt)
            )
        }
        let remoteEmployees = employees.map {
            RemoteDirectoryRecord(
                name: $0.name,
                unitPriceCents: nil,
                createdAt: CloudDate.isoString($0.createdAt),
                updatedAt: CloudDate.isoString($0.updatedAt)
            )
        }
        let batchNumbers = Dictionary(uniqueKeysWithValues: settlementBatches.map { ($0.id, $0.batchNo) })
        let remoteBills = bills.map { bill in
            RemoteBillRecord(
                date: DateKey.string(from: bill.date),
                submittedAt: CloudDate.isoString(bill.submittedAt),
                items: bill.items.map {
                    RemoteBillItemRecord(
                        customer: $0.customer,
                        employee: $0.employee,
                        model: $0.model,
                        quantity: $0.quantity,
                        colorCount: $0.colorCount,
                        unitPriceCents: $0.unitPriceCents,
                        settlementBatchNo: $0.settlementBatchID.flatMap { batchNumbers[$0] }
                    )
                }
            )
        }
        let remoteBatches = settlementBatches.map {
            RemoteSettlementBatchRecord(
                batchNo: $0.batchNo,
                customer: $0.customer,
                settlementDate: DateKey.string(from: $0.settlementDate),
                receivableCents: $0.receivableCents,
                actualAmountCents: $0.actualAmountCents,
                note: $0.note,
                createdAt: CloudDate.isoString($0.createdAt),
                revokedAt: $0.revokedAt.map(CloudDate.isoString)
            )
        }
        return RemoteWorkshopData(
            schemaVersion: 2,
            customers: remoteCustomers,
            employees: remoteEmployees,
            bills: remoteBills,
            settlementBatches: remoteBatches
        )
    }

    private func merge(_ data: RemoteWorkshopData) throws -> Int {
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        let count = try database.mergeRemoteWorkshop(data)
        customers = try database.loadCustomers()
        employees = try database.loadEmployees()
        bills = try database.loadBills()
        settlementBatches = try database.loadSettlementBatches()
        drafts = try database.loadDraftSummaries()
        return count
    }

    private func markCloudDirty(billDate: Date? = nil) {
        guard accountCanWrite, !mustChangePassword else { return }
        cloudChangeGeneration &+= 1
        hasPendingCloudChanges = true
        if let billDate {
            pendingBillDates.insert(DateKey.string(from: billDate))
        }
        persistPendingState()
        if activeSession == nil {
            cloudState = .localOnly
        } else {
            cloudState = .pending
            scheduleRetry(after: 2)
        }
    }

    private func markCloudClean() {
        hasPendingCloudChanges = false
        pendingBillDates.removeAll()
        persistPendingState()
    }

    private func scheduleRetry(after seconds: UInt64) {
        guard activeSession != nil, accountCanWrite, !mustChangePassword else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            let success = await self.syncNow(force: false)
            if !success, self.hasPendingCloudChanges, self.activeSession != nil {
                self.scheduleRetry(after: 30)
            }
        }
    }

    private func restoreLocalCloudMetadata() {
        hasPendingCloudChanges = defaults.bool(forKey: pendingKey)
        pendingBillDates = Set(defaults.stringArray(forKey: pendingDatesKey) ?? [])
        let timestamp = defaults.double(forKey: lastSyncKey)
        lastCloudSyncAt = timestamp > 0 ? Date(timeIntervalSince1970: timestamp) : nil
        lastCloudSnapshotName = defaults.string(forKey: snapshotNameKey)
        cloudRevision = defaults.integer(forKey: revisionKey)
    }

    private func persistPendingState() {
        defaults.set(hasPendingCloudChanges, forKey: pendingKey)
        defaults.set(Array(pendingBillDates).sorted(), forKey: pendingDatesKey)
    }

    private func persistCloudMetadata() {
        if let lastCloudSyncAt {
            defaults.set(lastCloudSyncAt.timeIntervalSince1970, forKey: lastSyncKey)
        }
        defaults.set(lastCloudSnapshotName, forKey: snapshotNameKey)
        defaults.set(cloudRevision, forKey: revisionKey)
        persistSessionMetadata()
    }

    private func friendlyCloudError(_ error: Error) -> String {
        if let remote = error as? RemoteLedgerError {
            if remote.errorCode == "writer_device_bound" {
                return "该账号已绑定另一台写入终端。请先在原设备解绑，或联系平台管理员紧急解绑。"
            }
            if remote.errorCode == "windows_device_bound" {
                return "该账号已绑定另一台 Windows 终端。请先解除原电脑绑定。"
            }
            if let message = remote.errorDescription {
                return message
            }
        }
        if let localized = error as? LocalizedError, let message = localized.errorDescription {
            return message
        }
        return error.localizedDescription
    }

    private func formatCloudTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func uniqueSorted(_ values: [String]) -> [String] {
        Array(Set(values.filter { !$0.isEmpty })).sorted { $0.localizedCompare($1) == .orderedAscending }
    }
}

enum EntrySource: Equatable {
    case new
    case draft
    case bill
}
