import SwiftUI

struct CloudBackupView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: () -> Void

    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var snapshots: [RemoteSnapshotRecord] = []
    @State private var alertItem: CloudAlertItem?

    var body: some View {
        WorkshopShell {
            WorkshopTopBar(
                brandTitle: "云端备份",
                brandSubtitle: "Cloud Backup",
                brandIcon: "icloud.and.arrow.up",
                backAction: onClose
            ) {
                LocalModeBadge(text: store.cloudBadgeText)
            }

            ScrollView {
                VStack(spacing: 18) {
                    PageHeading(
                        eyebrow: "正式账单备份",
                        title: "云端备份与恢复",
                        note: "每次提交后自动上传；草稿始终只保存在本机，不会进入云端。"
                    ) {
                        PageScopeBadge(label: "服务器", value: "ledger.893884474.xyz")
                    }

                    statusCard
                    accountCard
                    if store.isCloudLoggedIn {
                        actionCard
                        snapshotCard
                    }
                }
                .padding(.horizontal, 38)
                .padding(.top, 30)
                .padding(.bottom, 34)
            }
        }
        .task {
            loadSavedFields()
            if store.isCloudLoggedIn {
                await refreshSnapshots(showError: false)
                await store.refreshCloudStatus()
            }
        }
        .alert(item: $alertItem) { item in
            switch item {
            case .message(let title, let message):
                return Alert(
                    title: Text(title),
                    message: Text(message),
                    dismissButton: .default(Text("知道了"))
                )
            case .confirmLatest:
                return Alert(
                    title: Text("从服务器当前数据恢复？"),
                    message: Text("将合并服务器当前正式账单、客户、员工和型号；同一账单日期以服务器数据为准。本机独有记录会保留。"),
                    primaryButton: .destructive(Text("确认恢复")) {
                        Task { await restoreLatest() }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            case .confirmSnapshot(let snapshot):
                return Alert(
                    title: Text("恢复这个快照？"),
                    message: Text("快照：\(snapshot.fileName)\n\n将合并到本机，同一账单日期以该快照为准。服务器现有数据不会被立即覆盖。"),
                    primaryButton: .destructive(Text("恢复到本机")) {
                        Task { await restore(snapshot) }
                    },
                    secondaryButton: .cancel(Text("取消"))
                )
            }
        }
    }

    private var statusCard: some View {
        Panel {
            HStack(spacing: 18) {
                Image(systemName: store.isCloudLoggedIn ? "checkmark.icloud.fill" : "icloud.slash")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundColor(store.isCloudLoggedIn ? AppTheme.success : AppTheme.textFaint)
                    .frame(width: 52, height: 52)
                    .background(store.isCloudLoggedIn ? Color(red: 0.93, green: 0.97, blue: 0.95) : AppTheme.surfaceSoft)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(store.cloudBadgeText)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(AppTheme.text)
                    Text(store.cloudStatusText)
                        .font(.system(size: 13))
                        .foregroundColor(AppTheme.textMuted)
                    if let snapshot = store.lastCloudSnapshotName {
                        Text("最近快照：\(snapshot)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(AppTheme.textFaint)
                            .lineLimit(1)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("数据版本")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(AppTheme.textFaint)
                    Text("R\(store.cloudRevision)")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundColor(AppTheme.text)
                }
            }
            .padding(20)
        }
    }

    private var accountCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.isCloudLoggedIn ? "云端账号" : "登录云端账号")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(AppTheme.text)
                        Text(store.isCloudLoggedIn ? "凭据保存在系统钥匙串，不写入业务数据库。" : "客户端账号只上传正式账单和客户、员工档案。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    Spacer()
                    if store.isCloudLoggedIn {
                        Text("iPad 写权限")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(AppTheme.success)
                            .padding(.horizontal, 10)
                            .frame(height: 27)
                            .background(Color(red: 0.93, green: 0.97, blue: 0.95))
                            .clipShape(Capsule())
                    }
                }

                if store.isCloudLoggedIn {
                    HStack(spacing: 16) {
                        infoCell(label: "账号", value: store.cloudSession?.username ?? store.savedUsername)
                        infoCell(label: "服务器", value: store.cloudSession?.baseURL.absoluteString ?? store.savedBaseURLString)
                        Spacer()
                        Button("退出账号") {
                            Task { await logout() }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isWorking)
                    }
                } else {
                    HStack(spacing: 12) {
                        fieldLabel("服务器地址") {
                            TextField("https://ledger.893884474.xyz", text: $serverURL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        }
                        fieldLabel("客户端账号") {
                            TextField("请输入客户端账号", text: $username)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        }
                        fieldLabel("客户端密码") {
                            SecureField(store.hasSavedPassword ? "已保存，留空沿用" : "请输入客户端密码", text: $password)
                        }
                    }

                    HStack {
                        Text("服务器账号与管理员后台账号相互独立。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textFaint)
                        Spacer()
                        Button {
                            Task { await login() }
                        } label: {
                            HStack(spacing: 8) {
                                if isWorking {
                                    ProgressView().scaleEffect(0.65)
                                }
                                Text(isWorking ? "正在连接…" : "登录并同步")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isWorking)
                    }
                }
            }
            .padding(20)
        }
    }

    private var actionCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Text("数据操作")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(AppTheme.text)
                Text("提交账单后会自动上传。失败时会显示“待云端备份”，并每 30 秒自动重试。")
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textMuted)

                HStack(spacing: 12) {
                    Button {
                        Task { await forceSync() }
                    } label: {
                        HStack(spacing: 8) {
                            if isWorking { ProgressView().scaleEffect(0.65) }
                            Text(isWorking ? "请稍候…" : "立即同步 / 重新备份")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isWorking)

                    Button("从云端恢复当前数据") {
                        alertItem = .confirmLatest
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isWorking)

                    Spacer()
                }
            }
            .padding(20)
        }
    }

    private var snapshotCard: some View {
        Panel {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近 10 个成功快照")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(AppTheme.text)
                        Text("每日凌晨 02:00 生成全量快照，按月保存在服务器。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    Spacer()
                    Button("刷新列表") {
                        Task { await refreshSnapshots(showError: true) }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isWorking)
                }
                .padding(20)
                .overlay(Rectangle().fill(AppTheme.line).frame(height: 1), alignment: .bottom)

                if snapshots.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 28, weight: .light))
                            .foregroundColor(AppTheme.textFaint)
                        Text("暂无可用快照")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(AppTheme.text)
                        Text("服务器每天 02:00 后生成当天快照。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 150)
                } else {
                    ForEach(Array(snapshots.enumerated()), id: \.element.id) { index, snapshot in
                        snapshotRow(snapshot, alternate: !index.isMultiple(of: 2))
                        if index < snapshots.count - 1 {
                            Rectangle().fill(AppTheme.line).frame(height: 1).padding(.horizontal, 20)
                        }
                    }
                }
            }
        }
    }

    private func snapshotRow(_ snapshot: RemoteSnapshotRecord, alternate: Bool) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.fileName)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(AppTheme.text)
                    .lineLimit(1)
                Text("\(snapshot.localDate) · \(snapshot.formattedSize) · 数据版本 R\(snapshot.revision)")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.textMuted)
            }
            Spacer()
            Text(shortHash(snapshot.sha256))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(AppTheme.textFaint)
                .frame(width: 96, alignment: .trailing)
            Button("恢复到本机") {
                alertItem = .confirmSnapshot(snapshot)
            }
            .buttonStyle(SecondaryButtonStyle())
            .disabled(isWorking)
        }
        .padding(.horizontal, 20)
        .frame(minHeight: 64)
        .background(alternate ? AppTheme.surfaceSoft.opacity(0.7) : Color.white)
    }

    private func fieldLabel<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(AppTheme.textFaint)
            content()
                .font(.system(size: 14))
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(AppTheme.line, lineWidth: 1)
                )
        }
        .frame(maxWidth: .infinity)
    }

    private func infoCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(AppTheme.textFaint)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(AppTheme.text)
                .lineLimit(1)
        }
        .frame(minWidth: 180, alignment: .leading)
    }

    private func loadSavedFields() {
        serverURL = store.cloudSession?.baseURL.absoluteString ?? store.savedBaseURLString
        username = store.cloudSession?.username ?? store.savedUsername
    }

    private func login() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.login(baseURLString: serverURL, username: username, password: password)
            password = ""
            serverURL = store.savedBaseURLString
            username = store.savedUsername
            await refreshSnapshots(showError: false)
            if let error = store.lastCloudError {
                alertItem = .message("已登录，但首次同步失败", error)
            } else {
                alertItem = .message("登录成功", "正式账单已上传云端。草稿仍只保留在本机。")
            }
        } catch {
            alertItem = .message("登录失败", error.localizedDescription)
        }
    }

    private func logout() async {
        isWorking = true
        await store.logout()
        isWorking = false
        snapshots = []
        password = ""
        alertItem = .message("已退出云端账号", "本机账单不会删除；在重新登录前，新提交的正式账单会保持“待云端备份”。")
    }

    private func forceSync() async {
        isWorking = true
        let success = await store.syncNow(force: true)
        isWorking = false
        if success {
            await refreshSnapshots(showError: false)
            alertItem = .message("同步完成", "正式账单、客户和员工档案已备份到云端。")
        } else {
            alertItem = .message("同步失败", store.lastCloudError ?? "请检查网络后重试。")
        }
    }

    private func restoreLatest() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await store.restoreLatestWorkspace()
            await refreshSnapshots(showError: false)
            alertItem = .message(
                "云端恢复完成",
                "已合并 \(result.mergedBillCount) 个服务器账单日。\n来源：\(result.sourceLabel)\n服务器数据版本：R\(result.revision)"
            )
        } catch {
            alertItem = .message("恢复失败", error.localizedDescription)
        }
    }

    private func restore(_ snapshot: RemoteSnapshotRecord) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result = try await store.restoreSnapshot(snapshot)
            alertItem = .message(
                "快照已恢复到本机",
                "已合并 \(result.mergedBillCount) 个账单日。\n快照：\(result.sourceLabel)\n数据版本：R\(result.revision)\n\n如需把恢复后的数据设为云端当前数据，请再点击“立即同步”。"
            )
        } catch {
            alertItem = .message("快照恢复失败", error.localizedDescription)
        }
    }

    private func refreshSnapshots(showError: Bool) async {
        do {
            snapshots = try await store.listCloudSnapshots()
        } catch {
            if showError {
                alertItem = .message("无法读取快照列表", error.localizedDescription)
            }
        }
    }

    private func shortHash(_ value: String) -> String {
        String(value.prefix(10))
    }
}

private enum CloudAlertItem: Identifiable {
    case message(String, String)
    case confirmLatest
    case confirmSnapshot(RemoteSnapshotRecord)

    var id: String {
        switch self {
        case .message(let title, _): return "message-\(title)"
        case .confirmLatest: return "confirm-latest"
        case .confirmSnapshot(let snapshot): return "confirm-snapshot-\(snapshot.id)"
        }
    }
}
