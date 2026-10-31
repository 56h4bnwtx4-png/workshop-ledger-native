import SwiftUI

struct CloudBackupView: View {
    @EnvironmentObject private var store: AppStore
    let onClose: () -> Void

    @State private var isWorking = false
    @State private var snapshots: [RemoteSnapshotRecord] = []
    @State private var alertItem: CloudAlertItem?
    @State private var showPasswordForm = false
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var passwordError = ""

    var body: some View {
        WorkshopShell {
            WorkshopTopBar(
                brandTitle: "账号与备份",
                brandSubtitle: "Account & Backup",
                brandIcon: "person.crop.circle.badge.checkmark",
                backAction: onClose
            ) {
                LocalModeBadge(text: store.cloudBadgeText)
            }

            ScrollView {
                VStack(spacing: 18) {
                    PageHeading(
                        eyebrow: "账号数据",
                        title: "账号与云端备份",
                        note: "正式账单、客户和员工档案随账号同步；草稿始终只保存在当前设备。"
                    ) {
                        PageScopeBadge(label: "账号", value: store.accountDisplayName)
                    }

                    statusCard
                    accountCard
                    actionCard
                    snapshotCard
                }
                .padding(.horizontal, 38)
                .padding(.top, 30)
                .padding(.bottom, 34)
            }
        }
        .task {
            await refreshSnapshots(showError: false)
            await store.refreshCloudStatus()
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
                    message: Text("将合并服务器当前正式账单、客户和员工档案；同一账单日期以服务器数据为准。本机独有记录会保留。"),
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
            case .confirmUnbind:
                return Alert(
                    title: Text("解除当前 iPad 绑定？"),
                    message: Text("解除后这台 iPad 的登录令牌会立即失效。请把写入终端名额留给下一台设备；本机账号数据库也会从这台 iPad 删除。"),
                    primaryButton: .destructive(Text("确认解绑")) {
                        Task { await unbindDevice() }
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
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .foregroundColor(AppTheme.text)
                }
            }
            .padding(20)
        }
    }

    private var accountCard: some View {
        Panel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("当前账号与绑定设备")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundColor(AppTheme.text)
                        Text("写入终端名额由 iPad 与安卓共用；Windows 使用独立的只读名额。")
                            .font(.system(size: 12))
                            .foregroundColor(AppTheme.textMuted)
                    }
                    Spacer()
                    Text(store.isReadOnly ? "只读宽限期" : "写入终端")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(store.isReadOnly ? AppTheme.danger : AppTheme.success)
                        .padding(.horizontal, 10)
                        .frame(height: 27)
                        .background(store.isReadOnly ? AppTheme.dangerSoft : Color(red: 0.93, green: 0.97, blue: 0.95))
                        .clipShape(Capsule())
                }

                HStack(spacing: 16) {
                    infoCell(label: "车间名称", value: store.accountDisplayName)
                    infoCell(label: "登录账号", value: store.cloudSession?.username ?? "—")
                    infoCell(label: "服务器", value: store.cloudSession?.baseURL.absoluteString ?? "—")
                }

                HStack(spacing: 16) {
                    infoCell(label: "当前设备", value: store.boundDevice?.displayName ?? "—")
                    infoCell(label: "设备平台", value: platformLabel(store.boundDevice?.platform))
                    infoCell(label: "设备代次", value: "G\(store.boundDevice?.leaseGeneration ?? 0)")
                    infoCell(label: "账号状态", value: statusLabel(store.accountStatus))
                }

                if showPasswordForm {
                    Divider().overlay(AppTheme.line)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("修改登录密码")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundColor(AppTheme.text)
                        HStack(spacing: 12) {
                            passwordField("当前密码", text: $currentPassword)
                            passwordField("新密码（至少 10 位）", text: $newPassword)
                            passwordField("再次输入新密码", text: $confirmPassword)
                        }
                        if !passwordError.isEmpty {
                            Text(passwordError)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(AppTheme.danger)
                        }
                        HStack {
                            Spacer()
                            Button("取消") {
                                resetPasswordForm()
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(isWorking)
                            Button("保存新密码") {
                                Task { await changePassword() }
                            }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(isWorking)
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(showPasswordForm ? "收起修改密码" : "修改登录密码") {
                        showPasswordForm.toggle()
                        passwordError = ""
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isWorking)

                    Button("解除当前 iPad 绑定") {
                        alertItem = .confirmUnbind
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isWorking)

                    Spacer()

                    Button("退出账号") {
                        Task { await logout() }
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(isWorking)
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
                Text("提交账单后会自动上传。失败时显示“待云端备份”，并每 30 秒自动重试；账号只读时不会上传。")
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
                    .disabled(isWorking || store.isReadOnly)

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
                        Text("每日凌晨 02:00 生成全量快照，按月保存在服务器；服务器长期保留。")
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
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func passwordField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(AppTheme.textFaint)
            SecureField("", text: text)
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

    private func changePassword() async {
        guard !isWorking else { return }
        passwordError = ""
        guard newPassword.count >= 10 else {
            passwordError = "新密码至少需要 10 位。"
            return
        }
        guard newPassword == confirmPassword else {
            passwordError = "两次输入的新密码不一致。"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.changePassword(currentPassword: currentPassword, newPassword: newPassword)
            resetPasswordForm()
            alertItem = .message("密码已修改", "其他设备上的旧登录会话已由服务器撤销。")
        } catch {
            passwordError = error.localizedDescription
        }
    }

    private func resetPasswordForm() {
        showPasswordForm = false
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
        passwordError = ""
    }

    private func logout() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        let success = await store.logout()
        if success {
            snapshots = []
        } else {
            alertItem = .message("暂时不能退出", store.lastCloudError ?? "请先完成云端同步。")
        }
    }

    private func unbindDevice() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.unbindCurrentDevice()
            snapshots = []
        } catch {
            alertItem = .message("解绑失败", error.localizedDescription)
        }
    }

    private func forceSync() async {
        isWorking = true
        let success = await store.syncNow(force: true)
        isWorking = false
        if success {
            await refreshSnapshots(showError: false)
            alertItem = .message("同步完成", "正式账单、客户和员工档案已备份到当前账号。")
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

    private func platformLabel(_ value: String?) -> String {
        switch value {
        case "ios": return "iPadOS"
        case "android": return "Android"
        case "windows": return "Windows"
        default: return "—"
        }
    }

    private func statusLabel(_ value: String) -> String {
        switch value {
        case "active": return "正常"
        case "disabled": return "已停用 · 只读"
        case "expired": return "已到期 · 只读"
        case "deleted": return "已删除"
        default: return value
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
    case confirmUnbind

    var id: String {
        switch self {
        case .message(let title, _): return "message-\(title)"
        case .confirmLatest: return "confirm-latest"
        case .confirmSnapshot(let snapshot): return "confirm-snapshot-\(snapshot.id)"
        case .confirmUnbind: return "confirm-unbind"
        }
    }
}
