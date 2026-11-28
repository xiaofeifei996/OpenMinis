import SwiftUI

/// AutoClaw sign-in sheet (国内版：手机号 + 短信验证码).
///
/// 两跳协议：`agent-send-code` 发码 → `agent-login/` 换 token。两次请求必须带
/// **同一个** `device_id`（发码时不带会被上游判 400001），所以 device id 由发码
/// 那一步生成并在这里持有，登录成功后再交给 manager 落 Keychain。
///
/// 国际版的登录是另一套（OAuth + 阿里滑块风控），本面板只覆盖国内版；国际版请用
/// 自定义 Base URL + 手动粘贴 token。
struct AutoClawLoginSheet: View {
    let instanceId: String
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var phone = ""
    @State private var code = ""
    @State private var deviceID: String?
    @State private var isSending = false
    @State private var isSigningIn = false
    @State private var sentTo: String?
    @State private var errorMessage: String?
    @State private var countdown = 0
    @State private var countdownTask: Task<Void, Never>?

    private var phoneLooksValid: Bool {
        AutoClawAPI.normalizePhone(phone) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("手机号", text: $phone)
                        .keyboardType(.numberPad)
                        .textContentType(.telephoneNumber)

                    HStack {
                        TextField("验证码", text: $code)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                        Button(countdown > 0 ? "\(countdown)s" : "发送验证码") {
                            Task { await sendCode() }
                        }
                        .buttonStyle(.borderless)
                        .disabled(!phoneLooksValid || isSending || countdown > 0)
                    }
                } header: {
                    Text("登录 AutoClaw（智谱 AutoGLM）")
                } footer: {
                    Text("使用小浣熊同类之外的智谱账号登录。非官方接口，可能随时变更；请遵守上游服务条款，勿用于批量或商业用途。")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Spacer()
                            if isSigningIn {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(sentTo == nil ? "先获取验证码" : "登录")
                                    .font(.body.weight(.semibold))
                            }
                            Spacer()
                        }
                    }
                    .disabled(sentTo == nil || code.isEmpty || isSigningIn)
                }
            }
            .navigationTitle("AutoClaw")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { finish(false) }
                }
            }
            .onDisappear { countdownTask?.cancel() }
        }
    }

    private func sendCode() async {
        errorMessage = nil
        isSending = true
        defer { isSending = false }
        do {
            let id = try await AutoClawAPI.sendCode(phone: phone)
            deviceID = id
            sentTo = AutoClawAPI.normalizePhone(phone)
            startCountdown()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func signIn() async {
        guard let deviceID, let normalized = sentTo else { return }
        errorMessage = nil
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let credentials = try await AutoClawAPI.login(
                phone: normalized, code: code, deviceID: deviceID)
            let tail = "\(normalized.prefix(3))****\(normalized.suffix(4))"
            AutoClawAccountManager.shared.store(credentials, instanceId: instanceId, phoneTail: tail)
            finish(true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdown = 60
        countdownTask = Task { @MainActor in
            while countdown > 0 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                countdown -= 1
            }
        }
    }

    private func finish(_ success: Bool) {
        countdownTask?.cancel()
        onFinish(success)
        dismiss()
    }
}
