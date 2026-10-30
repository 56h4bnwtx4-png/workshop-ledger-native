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
    let username: String
    let baseURL: URL
    let expiresAt: Date?
    let scope: String
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
    @Published private(set) var drafts: [DraftSummary] = []
    @Published var lastError: String?

    @Published private(set) var cloudState: CloudSyncState = .localOnly
    @Published private(set) var cloudSession: CloudAccountSummary?
    @Published private(set) var hasPendingCloudChanges = false
    @Published private(set) var pendingBillDates: Set<String> = []
    @Published private(set) var lastCloudSyncAt: Date?
    @Published private(set) var lastCloudSnapshotName: String?
    @Published private(set) var cloudRevision: Int = 0
    @Published private(set) var lastCloudError: String?

    private let database: Database?
    private let remoteLedger: HTTPRemoteLedgerService
    private let defaults: UserDefaults
    private var activeSession: ActiveCloudSession?
    private var retryTask: Task<Void, Never>?
    private var syncInFlight = false
    private var cloudChangeGeneration = 0
    private var didStartCloud = false

    private let baseURLKey = "workshopLedger.cloud.baseURL.v1"
    private let usernameKey = "workshopLedger.cloud.username.v1"
    private let expiresAtKey = "workshopLedger.cloud.expiresAt.v1"
    private let pendingKey = "workshopLedger.cloud.pending.v1"
    private let pendingDatesKey = "workshopLedger.cloud.pendingBillDates.v1"
    private let lastSyncKey = "workshopLedger.cloud.lastSyncAt.v1"
    private let snapshotNameKey = "workshopLedger.cloud.lastSnapshotName.v1"
    private let revisionKey = "workshopLedger.cloud.revision.v1"
    private let tokenAccount = "session-token"
    private let passwordAccount = "account-password"

    init(
        remoteLedger: HTTPRemoteLedgerService = HTTPRemoteLedgerService(),
        defaults: UserDefaults = .standard
    ) {
        self.remoteLedger = remoteLedger
        self.defaults = defaults
        do {
            let database = try Database()
            self.database = database
            reloadAll()
        } catch {
            self.database = nil
            self.lastError = error.localizedDescription
        }
        restoreLocalCloudMetadata()
        restoreStoredSession()
    }

    var savedBaseURLString: String {
        defaults.string(forKey: baseURLKey) ?? CloudDefaults.baseURL
    }

    var savedUsername: String {
        defaults.string(forKey: usernameKey) ?? ""
    }

    var hasSavedPassword: Bool {
        KeychainStore.get(passwordAccount)?.isEmpty == false
    }

    var isCloudLoggedIn: Bool {
        activeSession != nil
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
                        colorCount: $0.colorCount
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
        guard let database else { return }
        do {
            try database.saveDraft(date: date, rows: rows)
            drafts = try database.loadDraftSummaries()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteDraft(date: Date) {
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
        guard let database else {
            throw DatabaseError.openFailed("数据库未打开")
        }
        let bill = try database.saveBill(date: date, rows: rows)
        customers = try database.loadCustomers()
        employees = try database.loadEmployees()
        bills = try database.loadBills()
        drafts = try database.loadDraftSummaries()
        markCloudDirty(billDate: date)
        return bill
    }

    func addCustomer(name: String) throws {
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        _ = try database.addCustomer(name: name)
        customers = try database.loadCustomers()
        markCloudDirty()
    }

    func updateCustomer(_ customer: Customer, name: String) throws {
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        try database.updateCustomer(id: customer.id, name: name)
        customers = try database.loadCustomers()
        markCloudDirty()
    }

    func deleteCustomer(_ customer: Customer) throws {
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        try database.deleteCustomer(id: customer.id)
        customers = try database.loadCustomers()
        markCloudDirty()
    }

    func addEmployee(name: String) throws {
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        _ = try database.addEmployee(name: name)
        employees = try database.loadEmployees()
        markCloudDirty()
    }

    func updateEmployee(_ employee: Employee, name: String) throws {
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        try database.updateEmployee(id: employee.id, name: name)
        employees = try database.loadEmployees()
        markCloudDirty()
    }

    func deleteEmployee(_ employee: Employee) throws {
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

    // MARK: - Cloud account

    func login(baseURLString: String, username: String, password: String) async throws {
        let normalizedURL = try normalizeBaseURL(baseURLString)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadPendingCloudChanges = hasPendingCloudChanges
        guard !normalizedUsername.isEmpty else {
            throw RemoteLedgerError.server(status: 400, message: "请输入客户端账号。")
        }
        let effectivePassword: String
        if password.isEmpty, let saved = KeychainStore.get(passwordAccount), !saved.isEmpty {
            effectivePassword = saved
        } else {
            effectivePassword = password
        }
        guard !effectivePassword.isEmpty else {
            throw RemoteLedgerError.server(status: 400, message: "请输入客户端密码。")
        }

        let response = try await remoteLedger.login(
            baseURL: normalizedURL,
            username: normalizedUsername,
            password: effectivePassword,
            clientType: CloudDefaults.clientType
        )
        let expiresAt = CloudDate.parse(response.expiresAt)
        let session = ActiveCloudSession(
            username: response.username,
            baseURL: normalizedURL,
            token: response.token,
            expiresAt: expiresAt,
            scope: response.scope
        )
        activeSession = session
        cloudSession = summary(for: session)
        KeychainStore.set(response.token, for: tokenAccount)
        KeychainStore.set(effectivePassword, for: passwordAccount)
        defaults.set(normalizedURL.absoluteString, forKey: baseURLKey)
        defaults.set(response.username, forKey: usernameKey)
        if let expiresAt {
            defaults.set(expiresAt.timeIntervalSince1970, forKey: expiresAtKey)
        }
        lastCloudError = nil
        cloudState = hasPendingCloudChanges ? .pending : .synced

        let remote = try await authorizedWorkspace()
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
    }

    func logout() async {
        retryTask?.cancel()
        if let activeSession {
            await remoteLedger.logout(baseURL: activeSession.baseURL, token: activeSession.token)
        }
        activeSession = nil
        cloudSession = nil
        KeychainStore.delete(tokenAccount)
        KeychainStore.delete(passwordAccount)
        defaults.removeObject(forKey: expiresAtKey)
        lastCloudError = nil
        cloudState = .localOnly
    }

    func applicationBecameActive() async {
        guard !didStartCloud else {
            if activeSession != nil {
                await refreshCloudStatus()
            }
            return
        }
        didStartCloud = true
        guard activeSession != nil else {
            cloudState = .localOnly
            return
        }
        if hasPendingCloudChanges {
            _ = await syncNow(force: true)
        } else {
            await refreshCloudStatus()
        }
    }

    @discardableResult
    func syncNow(force: Bool = false) async -> Bool {
        guard force || hasPendingCloudChanges else {
            await refreshCloudStatus()
            return cloudState != .failed("")
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
            scheduleRetry(after: 30)
            return false
        }
    }

    func refreshCloudStatus() async {
        guard activeSession != nil else {
            cloudState = .localOnly
            return
        }
        do {
            let remote = try await authorizedWorkspace()
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

    // MARK: - Cloud internals

    private struct ActiveCloudSession {
        let username: String
        let baseURL: URL
        let token: String
        let expiresAt: Date?
        let scope: String
    }

    private func restoreStoredSession() {
        guard let token = KeychainStore.get(tokenAccount), !token.isEmpty,
              let baseURLString = defaults.string(forKey: baseURLKey),
              let baseURL = URL(string: baseURLString),
              let username = defaults.string(forKey: usernameKey), !username.isEmpty else {
            return
        }
        let expiresAtValue = defaults.double(forKey: expiresAtKey)
        let expiresAt = expiresAtValue > 0 ? Date(timeIntervalSince1970: expiresAtValue) : nil
        if let expiresAt, expiresAt <= Date() {
            KeychainStore.delete(tokenAccount)
            return
        }
        let session = ActiveCloudSession(
            username: username,
            baseURL: baseURL,
            token: token,
            expiresAt: expiresAt,
            scope: "write"
        )
        activeSession = session
        cloudSession = summary(for: session)
        cloudState = hasPendingCloudChanges ? .pending : .synced
    }

    private func summary(for session: ActiveCloudSession) -> CloudAccountSummary {
        CloudAccountSummary(
            username: session.username,
            baseURL: session.baseURL,
            expiresAt: session.expiresAt,
            scope: session.scope
        )
    }

    private func normalizeBaseURL(_ value: String) throws -> URL {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), let host = url.host else {
            throw RemoteLedgerError.invalidURL
        }
        let isLocal = host == "localhost" || host == "127.0.0.1"
        guard scheme == "https" || (scheme == "http" && isLocal) else {
            throw RemoteLedgerError.server(status: 400, message: "公网服务器必须使用 HTTPS 地址。")
        }
        return url
    }

    private func authorizedWorkspace() async throws -> RemoteWorkspaceResponse {
        let session = try await validSession()
        do {
            return try await remoteLedger.fetchWorkspace(baseURL: session.baseURL, token: session.token)
        } catch RemoteLedgerError.unauthorized {
            let refreshed = try await relogin()
            return try await remoteLedger.fetchWorkspace(baseURL: refreshed.baseURL, token: refreshed.token)
        }
    }

    private func authorizedSave(_ data: RemoteWorkshopData) async throws -> RemoteSaveResponse {
        let session = try await validSession()
        do {
            return try await remoteLedger.saveWorkspace(baseURL: session.baseURL, token: session.token, data: data)
        } catch RemoteLedgerError.unauthorized {
            let refreshed = try await relogin()
            return try await remoteLedger.saveWorkspace(baseURL: refreshed.baseURL, token: refreshed.token, data: data)
        }
    }

    private func authorizedSnapshots() async throws -> [RemoteSnapshotRecord] {
        let session = try await validSession()
        do {
            return try await remoteLedger.listSnapshots(baseURL: session.baseURL, token: session.token)
        } catch RemoteLedgerError.unauthorized {
            let refreshed = try await relogin()
            return try await remoteLedger.listSnapshots(baseURL: refreshed.baseURL, token: refreshed.token)
        }
    }

    private func authorizedSnapshot(id: Int) async throws -> RemoteSnapshotEnvelope {
        let session = try await validSession()
        do {
            return try await remoteLedger.fetchSnapshot(baseURL: session.baseURL, token: session.token, id: id)
        } catch RemoteLedgerError.unauthorized {
            let refreshed = try await relogin()
            return try await remoteLedger.fetchSnapshot(baseURL: refreshed.baseURL, token: refreshed.token, id: id)
        }
    }

    private func validSession() async throws -> ActiveCloudSession {
        guard let activeSession else {
            throw RemoteLedgerError.unauthorized
        }
        if let expiresAt = activeSession.expiresAt, expiresAt <= Date() {
            return try await relogin()
        }
        return activeSession
    }

    private func relogin() async throws -> ActiveCloudSession {
        guard let username = defaults.string(forKey: usernameKey), !username.isEmpty,
              let baseURLString = defaults.string(forKey: baseURLKey),
              let password = KeychainStore.get(passwordAccount), !password.isEmpty else {
            throw RemoteLedgerError.unauthorized
        }
        let baseURL = try normalizeBaseURL(baseURLString)
        let response = try await remoteLedger.login(
            baseURL: baseURL,
            username: username,
            password: password,
            clientType: CloudDefaults.clientType
        )
        let expiresAt = CloudDate.parse(response.expiresAt)
        let session = ActiveCloudSession(
            username: response.username,
            baseURL: baseURL,
            token: response.token,
            expiresAt: expiresAt,
            scope: response.scope
        )
        activeSession = session
        cloudSession = summary(for: session)
        KeychainStore.set(response.token, for: tokenAccount)
        if let expiresAt {
            defaults.set(expiresAt.timeIntervalSince1970, forKey: expiresAtKey)
        }
        return session
    }

    private func buildRemoteWorkshopData() -> RemoteWorkshopData? {
        guard database != nil else { return nil }
        let remoteCustomers = customers.map {
            RemoteDirectoryRecord(
                name: $0.name,
                createdAt: CloudDate.isoString($0.createdAt),
                updatedAt: CloudDate.isoString($0.updatedAt)
            )
        }
        let remoteEmployees = employees.map {
            RemoteDirectoryRecord(
                name: $0.name,
                createdAt: CloudDate.isoString($0.createdAt),
                updatedAt: CloudDate.isoString($0.updatedAt)
            )
        }
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
                        colorCount: $0.colorCount
                    )
                }
            )
        }
        return RemoteWorkshopData(
            schemaVersion: 1,
            customers: remoteCustomers,
            employees: remoteEmployees,
            bills: remoteBills
        )
    }

    private func merge(_ data: RemoteWorkshopData) throws -> Int {
        guard let database else { throw DatabaseError.openFailed("数据库未打开") }
        let count = try database.mergeRemoteWorkshop(data)
        customers = try database.loadCustomers()
        employees = try database.loadEmployees()
        bills = try database.loadBills()
        drafts = try database.loadDraftSummaries()
        return count
    }

    private func markCloudDirty(billDate: Date? = nil) {
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
        guard activeSession != nil else { return }
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
    }

    private func friendlyCloudError(_ error: Error) -> String {
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
