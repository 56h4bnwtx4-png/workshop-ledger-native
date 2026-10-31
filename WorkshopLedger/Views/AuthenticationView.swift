import SwiftUI

struct AccountLoginView: View {
    @EnvironmentObject private var store: AppStore
    @State private var serverURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var errorMessage = ""

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "square.grid.2x2.fill")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 58, height: 58)
                        .background(AppTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text("车间计件")
                        .font(.system(size: 42, weight: .heavy, design: .rounded))
                        .foregroundColor(.white)
                    Text("原生 iPad 账本 · 云端独立账号")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.78))
                    Text("每台写入终端只能绑定一个账号。正式账单自动备份，草稿仍只保留在当前设备。")
                        .font(.system(size: 15))
                        .foregroundColor(Color.white.opacity(0.66))
                        .lineSpacing(5)
                        .frame(maxWidth: 430, alignment: .leading)
                    Spacer()
                    Text("固定横屏 · iPadOS 15+ · arm64")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.48))
                }
                .padding(54)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [Color(red: 0.08, green: 0.12, blue: 0.16), Color(red: 0.12, green: 0.18, blue: 0.22)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("账号登录")
                            .font(.system(size: 32, weight: .heavy))
                            .foregroundColor(AppTheme.text)
                        Text("使用平台管理员分配的独立账号。首次登录会要求修改临时密码。")
                            .font(.system(size: 14))
                            .foregroundColor(AppTheme.textMuted)
                            .lineSpacing(3)
                    }

                    VStack(spacing: 16) {
                        loginField(title: "服务器地址") {
                            TextField("https://ledger.893884474.xyz", text: $serverURL)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        }
                        loginField(title: "登录账号") {
                            TextField("请输入账号", text: $username)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                        }
                        loginField(title: "密码") {
                            SecureField("请输入密码", text: $password)
                                .onSubmit { Task { await login() } }
                        }
                    }

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.danger)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.dangerSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    Button {
                        Task { await login() }
                    } label: {
                        HStack(spacing: 9) {
                            if isWorking { ProgressView().scaleEffect(0.7) }
                            Text(isWorking ? "正在登录…" : "登录")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(isWorking)

                    Text("账号、临时密码不会写入本机偏好设置；登录令牌仅保存在系统钥匙串。")
                        .font(.system(size: 11))
                        .foregroundColor(AppTheme.textFaint)
                }
                .padding(44)
                .frame(width: 520)
                .frame(maxHeight: .infinity, alignment: .center)
                .background(Color.white)
            }
        }
        .onAppear {
            serverURL = store.savedBaseURLString
            username = store.savedUsername
        }
    }

    private func loginField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppTheme.textMuted)
            content()
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .frame(height: 48)
                .background(AppTheme.surfaceSoft)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.line, lineWidth: 1)
                )
        }
    }

    private func login() async {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = ""
        defer { isWorking = false }
        do {
            try await store.login(baseURLString: serverURL, username: username, password: password)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct RequiredPasswordChangeView: View {
    @EnvironmentObject private var store: AppStore
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isWorking = false
    @State private var errorMessage = ""

    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            Panel {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: "lock.rotation")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(AppTheme.accent)
                            .frame(width: 52, height: 52)
                            .background(Color(red: 1.0, green: 0.94, blue: 0.88))
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text("首次登录必须修改密码")
                                .font(.system(size: 26, weight: .heavy))
                                .foregroundColor(AppTheme.text)
                            Text("账号：\(store.cloudSession?.username ?? "") · \(store.accountDisplayName)")
                                .font(.system(size: 13))
                                .foregroundColor(AppTheme.textMuted)
                        }
                    }

                    Text("请输入登录时使用的临时密码，再设置至少 10 位的新密码。修改成功后会自动进入账本。")
                        .font(.system(size: 14))
                        .foregroundColor(AppTheme.textMuted)
                        .lineSpacing(3)

                    passwordField("当前临时密码", text: $currentPassword)
                    passwordField("新密码", text: $newPassword)
                    passwordField("再次输入新密码", text: $confirmPassword)

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(AppTheme.danger)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.dangerSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }

                    HStack(spacing: 12) {
                        Button("返回登录") {
                            Task { _ = await store.logout(force: true) }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isWorking)
                        Spacer()
                        Button {
                            Task { await changePassword() }
                        } label: {
                            HStack(spacing: 8) {
                                if isWorking { ProgressView().scaleEffect(0.7) }
                                Text(isWorking ? "正在修改…" : "修改密码并进入")
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isWorking)
                    }
                }
                .padding(30)
            }
            .frame(width: 560)
            .padding(40)
        }
    }

    private func passwordField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppTheme.textMuted)
            SecureField("至少 10 位", text: text)
                .font(.system(size: 15))
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(AppTheme.surfaceSoft)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(AppTheme.line, lineWidth: 1)
                )
        }
    }

    private func changePassword() async {
        guard !isWorking else { return }
        errorMessage = ""
        guard newPassword.count >= 10 else {
            errorMessage = "新密码至少需要 10 位。"
            return
        }
        guard newPassword == confirmPassword else {
            errorMessage = "两次输入的新密码不一致。"
            return
        }
        isWorking = true
        defer { isWorking = false }
        do {
            try await store.completeRequiredPasswordChange(currentPassword: currentPassword, newPassword: newPassword)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
