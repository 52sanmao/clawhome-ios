//
//  TerminalConnectView.swift
//  contextgo
//
//  Terminal authorization confirmation screen
//  Shown when scanning a CLI's QR code or opening a deep link
//

import SwiftUI

struct TerminalConnectView: View {
    let cliPublicKey: String
    let agent: CloudAgent?
    var onAuthComplete: ((String, Data) -> Void)?  // (token, masterSecret) callback

    @Environment(\.dismiss) private var dismiss
    @StateObject private var authService = TerminalAuthService()
    @State private var showSuccess: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                // Icon
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 64))
                    .foregroundColor(.blue)
                    .padding(.bottom, 8)

                // Title
                Text("连接终端")
                    .font(.title2.bold())

                // Description
                Text("一个 CLI 终端请求连接到你的 ContextGo 账户。确认后将安全地共享加密凭证。")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                // Public key preview
                VStack(spacing: 8) {
                    Text("终端公钥")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(publicKeyPreview)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(12)
                        .frame(maxWidth: .infinity)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                }
                .padding(.horizontal, 32)

                // Server info
                if let agent = agent, let config = try? agent.cliRelayConfig() {
                    HStack(spacing: 8) {
                        Image(systemName: "server.rack")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        Text(config.serverURL)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                // Error
                if let error = authService.error {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(.horizontal, 32)
                }

                // Action buttons
                VStack(spacing: 12) {
                    // Accept button
                    Button {
                        acceptConnection()
                    } label: {
                        HStack {
                            if authService.isLoading {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            }
                            Text(authService.isLoading ? "授权中..." : "接受连接")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                    }
                    .disabled(authService.isLoading)

                    // Reject button
                    Button {
                        dismiss()
                    } label: {
                        Text("拒绝")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .foregroundColor(.red)
                    }
                    .disabled(authService.isLoading)
                }
                .padding(.horizontal, 32)
                .padding(.bottom, 32)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .alert("授权成功", isPresented: $showSuccess) {
                Button("完成") {
                    dismiss()
                }
            } message: {
                Text("CLI 终端已成功授权。现在可以在终端中使用 ContextGo 了。")
            }
        }
    }

    // MARK: - Computed

    private var publicKeyPreview: String {
        if cliPublicKey.count > 20 {
            return String(cliPublicKey.prefix(8)) + "..." + String(cliPublicKey.suffix(8))
        }
        return cliPublicKey
    }

    // MARK: - Actions

    private func acceptConnection() {
        guard let agent = agent else {
            print("[TerminalConnect] ERROR: No agent provided")
            return
        }

        // Set server config from agent
        if let config = try? agent.cliRelayConfig() {
            print("[TerminalConnect] Setting server config - URL: \(config.serverURL)")
            authService.activeServerConfig = TerminalAuthService.ServerConfig(
                serverURL: config.serverURL
            )
        } else {
            print("[TerminalConnect] WARNING: No serverURL - using default")
        }

        print("[TerminalConnect] Starting authorization with key: \(cliPublicKey.prefix(12))...")
        Task {
            do {
                try await authService.authorizeTerminal(cliPublicKeyBase64: cliPublicKey)
                print("[TerminalConnect] Authorization succeeded!")

                // Save token and master secret to agent via callback
                if let token = authService.authToken, let secret = authService.masterSecret {
                    print("[TerminalConnect] Saving credentials to agent - token: \(token.prefix(12))...")
                    onAuthComplete?(token, secret)
                }

                showSuccess = true
            } catch {
                print("[TerminalConnect] Authorization failed: \(error)")
            }
        }
    }
}

#Preview {
    TerminalConnectView(
        cliPublicKey: "AbCd1234567890EfGhIjKlMnOpQrStUvWxYz1234567890",
        agent: nil  // CloudAgent would go here
    )
}
