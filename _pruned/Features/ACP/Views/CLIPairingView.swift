//
//  CLIPairingView.swift
//  contextgo
//
//  QR code pairing for CLI relay server
//  Supports two modes:
//  1. Server pairing: QR contains serverURL + token (original)
//  2. Terminal auth: QR contains ctxgo://terminal?{payload} (E2E encrypted)
//

import SwiftUI

struct CLIPairingView: View {
    let agent: CloudAgent
    @Environment(\.dismiss) private var dismiss
    @State private var serverURL: String = CoreServerDefaults.relayServerURL
    @State private var token: String = ""
    @State private var showScanner: Bool = false
    @State private var isPairing: Bool = false
    @State private var pairingError: String?
    @State private var showError: Bool = false
    @State private var showTerminalConnect: Bool = false
    @State private var terminalPublicKey: String?
    // Device info extracted from QR scan (for Core device registration)
    @State private var scannedMachineId: String?
    @State private var scannedAgentType: String?
    @State private var scannedRuntimeServer: String?

    var onPairingComplete: ((String, String, Data?) -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        showScanner = true
                    } label: {
                        Label("扫描 QR 码", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Section(header: Text("或手动输入")) {
                    TextField("Server URL", text: $serverURL)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)

                    TextField("Token", text: $token)
                        .textContentType(.password)
                        .autocapitalization(.none)
                }

                Section {
                    Button("连接") {
                        pairWithServer()
                    }
                    .disabled(serverURL.isEmpty || token.isEmpty || isPairing)

                    if isPairing {
                        HStack {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle())
                            Text("配对中...")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("配对 ContextGo Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerView { data in
                    print("[CLIPairing] QR scan result - isTerminalAuth: \(data.isTerminalAuth), serverURL: '\(data.serverURL)', terminalPublicKey: \(data.terminalPublicKey?.prefix(12) ?? "nil")")
                    if data.isTerminalAuth, let publicKey = data.terminalPublicKey {
                        // Terminal auth mode: store device info and show TerminalConnectView
                        print("[CLIPairing] Routing to TerminalConnectView with key: \(publicKey.prefix(12))...")
                        terminalPublicKey = publicKey
                        scannedMachineId = data.machineId
                        scannedAgentType = data.agentType
                        scannedRuntimeServer = data.runtimeServer
                        showTerminalConnect = true
                        // Register runtime device in Core in background
                        if let machineId = data.machineId {
                            Task { await registerRuntimeDeviceInCore(machineId: machineId, agentType: data.agentType, runtimeServer: data.runtimeServer) }
                        }
                    } else {
                        // Server pairing mode: fill in fields and auto-pair
                        serverURL = data.serverURL
                        token = data.token
                        if !serverURL.isEmpty && !token.isEmpty {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                pairWithServer()
                            }
                        }
                    }
                }
            }
            .sheet(isPresented: $showTerminalConnect) {
                if let publicKey = terminalPublicKey {
                    TerminalConnectView(
                        cliPublicKey: publicKey,
                        agent: agent
                    )
                }
            }
            .alert("配对失败", isPresented: $showError) {
                Button("确定", role: .cancel) {}
            } message: {
                if let error = pairingError {
                    Text(error)
                }
            }
            .onAppear {
                let configuredRelay = CoreConfig.shared.cliRelayServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if !configuredRelay.isEmpty {
                    serverURL = configuredRelay
                }
            }
        }
    }

    // MARK: - Pairing Logic

    /// Register CLI runtime device in Core after QR scan (best-effort, does not block pairing flow)
    private func registerRuntimeDeviceInCore(machineId: String, agentType: String?, runtimeServer: String?) async {
        guard CoreConfig.shared.isConfigured else {
            print("[CLIPairing] Core not configured, skipping runtime device registration")
            return
        }

        // We need token and secret from agent config to decrypt machine metadata
        // This will be called from TerminalConnectView's onAuthComplete where we have those
        print("[CLIPairing] ⚠️ registerRuntimeDeviceInCore called but missing auth credentials")
        print("[CLIPairing] This should be called from onAuthComplete where token/secret are available")
    }

    private func pairWithServer() {
        isPairing = true
        pairingError = nil

        // Validate URL
        guard let url = URL(string: serverURL), url.scheme != nil else {
            pairingError = "无效的服务器 URL"
            showError = true
            isPairing = false
            return
        }

        // Generate or use existing secret key
        let secretKey = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        // Test connection
        Task {
            do {
                // Simple validation - actual connection happens in ConnectionManager
                try await Task.sleep(nanoseconds: 500_000_000) // 0.5s

                // Call completion handler
                onPairingComplete?(serverURL, token, secretKey)

                await MainActor.run {
                    isPairing = false
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    pairingError = "连接失败: \(error.localizedDescription)"
                    showError = true
                    isPairing = false
                }
            }
        }
    }
}

#Preview {
    // CloudAgent preview would go here
    CLIPairingView(agent: CloudAgent(
        id: "preview-id",
        name: "claude-code",
        displayName: "Claude Code",
        description: "Test",
        type: "claudecode",
        config: "{}",
        permissions: "{}",
        status: "active",
        createdAt: Date(),
        updatedAt: Date()
    ))
}
