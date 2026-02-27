//
//  CoreSettingsView.swift
//  contextgo
//
//  ContextGo Core 配置与登录 — 支持多用户 JWT 认证（邮箱/密码 + OAuth）
//

import SwiftUI
import AuthenticationServices
import UIKit

struct CoreSettingsView: View {
    @ObservedObject private var coreConfig = CoreConfig.shared

    // 配置输入
    @State private var endpointInput: String = ""

    // 登录/注册输入
    @State private var emailInput: String = ""
    @State private var passwordInput: String = ""
    @State private var displayNameInput: String = ""
    @State private var isRegistering: Bool = false

    // OAuth providers 列表
    @State private var oauthProviders: [String] = []
    @State private var loadedProviders: Bool = false

    // 状态
    @State private var isLoading: Bool = false
    @State private var statusMessage: StatusMessage? = nil

    struct StatusMessage: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    var body: some View {
        Form {
            // ── 连接状态 ─────────────────────────────────────────────
            Section {
                HStack(spacing: 8) {
                    Image(systemName: coreConfig.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(coreConfig.isConfigured ? .green : .orange)
                    if coreConfig.isConfigured {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("已登录 · \(coreConfig.userEmail)")
                                .font(.subheadline.bold())
                            Text(coreConfig.endpoint)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("未配置 — 请填写地址并登录")
                            .foregroundColor(.secondary)
                            .font(.caption)
                    }
                }
            }

            // ── Core 地址 ─────────────────────────────────────────────
            Section {
                TextField(CoreServerDefaults.coreEndpoint, text: $endpointInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(.body, design: .monospaced))

                Button("测试连接并检测 OAuth") {
                    Task {
                        await testHealth()
                        await loadOAuthProviders()
                    }
                }
                .disabled(endpointInput.trimmingCharacters(in: .whitespaces).isEmpty)

            } header: {
                Text("Core 服务地址")
            } footer: {
                Text("contextgo-core 的 HTTP 地址")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // ── OAuth 登录 ────────────────────────────────────────────
            if !coreConfig.isConfigured && !oauthProviders.isEmpty {
                Section {
                    ForEach(oauthProviders, id: \.self) { provider in
                        Button {
                            startOAuth(provider: provider)
                        } label: {
                            HStack {
                                Image(systemName: provider == "github" ? "chevron.left.forwardslash.chevron.right" : "globe")
                                Text("使用 \(provider.capitalized) 登录")
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                    }
                } header: {
                    Text("快捷登录")
                }
            }

            // ── 邮箱/密码登录 ─────────────────────────────────────────
            if !coreConfig.isConfigured {
                Section {
                    // 模式切换
                    Picker("", selection: $isRegistering) {
                        Text("登录").tag(false)
                        Text("注册").tag(true)
                    }
                    .pickerStyle(.segmented)

                    TextField("邮箱", text: $emailInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.emailAddress)

                    SecureField("密码（至少8位）", text: $passwordInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    if isRegistering {
                        TextField("显示名称", text: $displayNameInput)
                            .autocorrectionDisabled()
                    }

                    Button {
                        Task { await loginOrRegister() }
                    } label: {
                        HStack {
                            if isLoading {
                                ProgressView().scaleEffect(0.8)
                            } else {
                                Image(systemName: isRegistering ? "person.badge.plus" : "arrow.right.circle")
                            }
                            Text(isRegistering ? "注册并登录" : "登录")
                        }
                    }
                    .disabled(isLoading || emailInput.isEmpty || passwordInput.isEmpty || endpointInput.isEmpty)

                } header: {
                    Text(isRegistering ? "创建账户" : "邮箱登录")
                }
            }

            // ── 已登录操作 ───────────────────────────────────────────
            if coreConfig.isConfigured {
                Section {
                    Button(role: .destructive) {
                        logout()
                    } label: {
                        HStack {
                            Image(systemName: "arrow.backward.circle")
                            Text("退出登录")
                        }
                    }
                }
            }

            // ── 状态消息 ─────────────────────────────────────────────
            if let status = statusMessage {
                Section {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: status.isError ? "xmark.circle.fill" : "checkmark.circle.fill")
                            .foregroundColor(status.isError ? .red : .green)
                        Text(status.text)
                            .foregroundColor(status.isError ? .red : .green)
                            .font(.caption)
                    }
                }
            }

            // ── 说明 ─────────────────────────────────────────────────
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("什么是 ContextGo Core?")
                        .font(.caption.bold())
                    Text("contextgo-core 是私有部署的上下文管理服务，负责存储 Context、Task、Skill 等数据。多用户模式下，每个用户的数据完全隔离。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Core 服务配置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            endpointInput = coreConfig.endpoint
            if !endpointInput.isEmpty && !loadedProviders {
                Task { await loadOAuthProviders() }
            }
            // Note: OAuth callback now handled at app level (contextgoApp.swift)
            // to ensure device registration happens even if user navigates away
        }
    }

    // MARK: - Actions

    private func testHealth() async {
        guard let ep = validatedEndpoint() else {
            statusMessage = StatusMessage(text: "无效的 Core 地址", isError: true)
            return
        }
        endpointInput = ep
        guard let url = CoreConfig.composeURL(endpoint: ep, path: "/health") else {
            statusMessage = StatusMessage(text: "无效的 URL", isError: true)
            return
        }

        do {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.httpMethod = "GET"
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                statusMessage = StatusMessage(text: "Core 服务正常运行", isError: false)
            } else {
                statusMessage = StatusMessage(text: "服务器响应异常", isError: true)
            }
        } catch {
            statusMessage = StatusMessage(text: error.localizedDescription, isError: true)
        }
    }

    private func loadOAuthProviders() async {
        guard let ep = validatedEndpoint() else { return }
        endpointInput = ep
        guard let url = CoreConfig.composeURL(endpoint: ep, path: "/api/oauth/providers") else { return }

        do {
            let (data, resp) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 5))
            if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                struct ProvidersResp: Decodable { let providers: [String] }
                let decoded = try JSONDecoder().decode(ProvidersResp.self, from: data)
                await MainActor.run { oauthProviders = decoded.providers; loadedProviders = true }
            }
        } catch {}
    }

    private func startOAuth(provider: String) {
        guard let ep = validatedEndpoint() else {
            statusMessage = StatusMessage(text: "无效的 Core 地址", isError: true)
            return
        }
        endpointInput = ep
        guard let url = CoreConfig.composeURL(endpoint: ep, path: "/api/oauth/\(provider)") else { return }

        // Save endpoint before OAuth so deep link handler can use it
        coreConfig.endpoint = ep

        // Open in ASWebAuthenticationSession for proper OAuth redirect handling
        let session = ASWebAuthenticationSession(
            url: url,
            callbackURLScheme: "contextgo"
        ) { callbackURL, error in
            if let error = error {
                statusMessage = StatusMessage(text: error.localizedDescription, isError: true)
                return
            }
            // OAuth callback (contextgo://auth?token=xxx) is handled by app-level
            // handleOAuthCallback in contextgoApp.swift, which registers the device
        }
        session.prefersEphemeralWebBrowserSession = false
        session.start()
    }

    private func loginOrRegister() async {
        isLoading = true
        statusMessage = nil

        guard let ep = validatedEndpoint() else {
            statusMessage = StatusMessage(text: "无效的 Core 地址", isError: true)
            isLoading = false
            return
        }
        endpointInput = ep
        let path = isRegistering ? "api/auth/register" : "api/auth/login"
        guard let url = CoreConfig.composeURL(endpoint: ep, path: path) else {
            statusMessage = StatusMessage(text: "无效的 URL", isError: true)
            isLoading = false
            return
        }

        struct AuthRequest: Encodable {
            let email: String
            let password: String
            let displayName: String?
        }

        struct AuthResponse: Decodable {
            let success: Bool
            let token: String?
            let error: String?
            let user: UserInfo?
            struct UserInfo: Decodable {
                let email: String
                let displayName: String
            }
        }

        do {
            var req = URLRequest(url: url, timeoutInterval: 15)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body = AuthRequest(
                email: emailInput.trimmingCharacters(in: .whitespaces),
                password: passwordInput,
                displayName: isRegistering ? (displayNameInput.isEmpty ? nil : displayNameInput) : nil
            )
            req.httpBody = try JSONEncoder().encode(body)

            let (data, _) = try await URLSession.shared.data(for: req)
            let decoded = try JSONDecoder().decode(AuthResponse.self, from: data)

            if decoded.success, let token = decoded.token {
                coreConfig.endpoint = ep
                coreConfig.saveJWT(token)
                coreConfig.userEmail = decoded.user?.email ?? emailInput
                coreConfig.displayName = decoded.user?.displayName ?? ""
                statusMessage = StatusMessage(text: "登录成功！", isError: false)
                passwordInput = ""
                // AuthService will handle device registration when it checks authentication
                await AuthService.shared.checkAuthentication()
            } else {
                statusMessage = StatusMessage(text: decoded.error ?? "登录失败", isError: true)
            }
        } catch {
            statusMessage = StatusMessage(text: error.localizedDescription, isError: true)
        }

        isLoading = false
    }

    private func validatedEndpoint() -> String? {
        guard let baseURL = CoreConfig.endpointBaseURL(from: endpointInput) else {
            return nil
        }
        return baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func logout() {
        coreConfig.clearAuth()
        oauthProviders = []
        loadedProviders = false
        emailInput = ""
        passwordInput = ""
        statusMessage = nil
    }
}

#Preview {
    NavigationView {
        CoreSettingsView()
    }
}
