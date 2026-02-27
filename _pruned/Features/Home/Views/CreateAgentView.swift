import SwiftUI
import PhotosUI

// MARK: - Agent Type Definition

enum AgentType: String, CaseIterable, Identifiable {
    case openClaw = "OpenClaw"
    case claudeCode = "Claude Code"
    case codeX = "CodeX"
    case geminiCli = "Gemini CLI"
    case openCode = "OpenCode"

    var id: String { rawValue }

    // Use asset logo if available, otherwise use system icon
    var logoImageName: String? {
        switch self {
        case .openClaw: return "OpenClawLogo"
        case .claudeCode: return "ClaudeCodeLogo"
        case .codeX: return "CodexLogo"
        case .openCode: return "OpenCodeLogo"
        case .geminiCli: return "GeminiCliLogo"
        }
    }

    var icon: String {
        switch self {
        case .openClaw: return "pawprint.fill"
        case .claudeCode: return "terminal.fill"
        case .geminiCli: return "sparkles"
        case .codeX: return "chevron.left.forwardslash.chevron.right"
        case .openCode: return "curlybraces"
        }
    }

    var color: Color {
        // ✅ 统一使用灰色调，符合系统整体黑白灰设计
        switch self {
        case .openClaw: return .gray
        case .claudeCode: return .gray
        case .geminiCli: return .gray
        case .codeX: return .gray
        case .openCode: return .gray
        }
    }

    var isSupported: Bool {
        switch self {
        case .openClaw, .claudeCode, .codeX, .openCode, .geminiCli:
            return true
        }
    }

}

// MARK: - Create Agent View

struct CreateAgentView: View {
    @EnvironmentObject var homeViewModel: HomeViewModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    // Form States
    @State private var selectedType: AgentType = .openClaw
    @State private var agentName: String = ""
    @State private var customLogoImage: UIImage? = nil
    @State private var selectedPhotoItem: PhotosPickerItem? = nil

    // QR Scanning & Configuration
    @State private var showQRScanner: Bool = false
    @State private var scannedURL: String? = nil
    @State private var cliRelayServerURL: String = CoreServerDefaults.relayServerURL
    @State private var manualAuthInput: String = ""

    // Terminal Auth
    @State private var showTerminalConnect: Bool = false
    @State private var terminalPublicKey: String?
    @State private var terminalMachineId: String?
    @State private var terminalRuntimeServer: String?
    @State private var scannedAgentType: String?
    @State private var terminalAgent: CloudAgent?  // 直接存储 Agent 对象

    // UI States
    @State private var showValidationError: Bool = false
    @State private var errorMessage: String = ""
    @State private var isConnecting: Bool = false

    let maxNameLength = 20

    var isFormValid: Bool {
        // Unsupported types cannot be created
        if !selectedType.isSupported {
            return false
        }

        // OpenClaw needs scanned URL or manual input
        if selectedType == .openClaw {
            return isValidOpenClawGatewayURL(scannedURL)
        }

        if selectedType == .claudeCode || selectedType == .codeX || selectedType == .openCode || selectedType == .geminiCli {
            return terminalPublicKey != nil || !manualAuthInput.isEmpty
        }

        return false
    }

    var effectiveBotName: String {
        agentName.isEmpty ? selectedType.rawValue : agentName
    }

    private var expectedTerminalAgentType: String? {
        switch selectedType {
        case .claudeCode:
            return "claudecode"
        case .codeX:
            return "codex"
        case .openCode:
            return "opencode"
        case .geminiCli:
            return "geminicli"
        case .openClaw:
            return nil
        }
    }

    private func cloudAgentType(for selectedType: AgentType) -> String {
        switch selectedType {
        case .openClaw:
            return "openclaw"
        case .claudeCode:
            return "claudecode"
        case .codeX:
            return "codex"
        case .geminiCli:
            return "geminicli"
        case .openCode:
            return "opencode"
        }
    }

    private func normalizeTerminalAgentType(_ type: String?) -> String? {
        guard let raw = type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return nil
        }

        let allowedTypes: Set<String> = ["claudecode", "codex", "geminicli", "opencode"]
        return allowedTypes.contains(raw) ? raw : nil
    }

    var body: some View {
        NavigationView {
            ZStack {
                theme.primaryBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Section 1: Agent Type Selection
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Agent Type")
                                .font(.headline)
                                .foregroundColor(theme.primaryText)

                            LazyVGrid(
                                columns: [
                                    GridItem(.flexible()),
                                    GridItem(.flexible())
                                ],
                                spacing: 8
                            ) {
                                ForEach(AgentType.allCases) { type in
                                    AgentTypeCard(
                                        type: type,
                                        isSelected: selectedType == type,
                                        colorScheme: colorScheme
                                    ) {
                                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                            selectedType = type
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 24)

                        // Section 2: Agent Logo & Name (only for supported types)
                        if selectedType.isSupported {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Agent Name")
                                        .font(.headline)
                                        .foregroundColor(theme.primaryText)
                                    Spacer()
                                    Text("\(agentName.count)/\(maxNameLength)")
                                        .font(.caption)
                                        .foregroundColor(agentName.count >= maxNameLength ? .red : theme.secondaryText)
                                }

                                HStack(spacing: 16) {
                                    // Clickable Logo
                                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                        ZStack {
                                            if let customImage = customLogoImage {
                                                // User uploaded custom logo
                                                Image(uiImage: customImage)
                                                    .resizable()
                                                    .scaledToFill()
                                                    .frame(width: 60, height: 60)
                                                    .clipShape(Circle())
                                            } else {
                                                // Default: Channel logo
                                                Circle()
                                                    .fill(selectedType.color.opacity(0.2))
                                                    .frame(width: 60, height: 60)

                                                if let logoImageName = selectedType.logoImageName {
                                                    Image(logoImageName)
                                                        .resizable()
                                                        .scaledToFill()
                                                        .frame(width: 60, height: 60)
                                                        .clipShape(Circle())
                                                }
                                            }

                                            // Camera icon overlay hint
                                            Circle()
                                                .fill(Color.black.opacity(0.5))
                                                .frame(width: 60, height: 60)
                                                .overlay(
                                                    Image(systemName: "camera.fill")
                                                        .font(.caption)
                                                        .foregroundColor(.white)
                                                )
                                                .opacity(0.0)
                                        }
                                    }

                                    TextField("Enter agent name", text: $agentName)
                                        .onChange(of: agentName) { _, newValue in
                                            if newValue.count > maxNameLength {
                                                agentName = String(newValue.prefix(maxNameLength))
                                            }
                                        }
                                        .padding(16)
                                        .background(theme.cardBackground)
                                        .cornerRadius(12)
                                        .foregroundColor(theme.primaryText)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(theme.border, lineWidth: 1)
                                        )
                                }
                            }
                            .padding(.horizontal, 24)
                        }

                        // Section 3: Configuration
                        VStack(alignment: .leading, spacing: 16) {
                            Text(configurationTitle)
                                .font(.headline)
                                .foregroundColor(theme.primaryText)

                            if selectedType.isSupported {
                                configurationView
                            } else {
                                // Simple unsupported message
                                Text("\(selectedType.rawValue) 渠道即将上线，敬请期待")
                                    .font(.subheadline)
                                    .foregroundColor(theme.secondaryText)
                                    .padding(.vertical, 8)
                            }
                        }
                        .padding(.horizontal, 24)

                        // Validation Error
                        if showValidationError {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.red)
                                Text(errorMessage)
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }
                            .padding(12)
                            .background(Color.red.opacity(0.1))
                            .cornerRadius(8)
                            .padding(.horizontal, 24)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        Spacer().frame(height: 40)
                    }
                    .padding(.top, 20)
                }
            }
            .navigationTitle("Create Agent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundColor(theme.primaryText)
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Create") {
                        handleCreate()
                    }
                    .foregroundColor(isFormValid ? theme.accentBlue : theme.tertiaryText)
                    .fontWeight(.semibold)
                    .disabled(!isFormValid)
                }
            }
        }
        .sheet(isPresented: $showQRScanner) {
            QRCodeScannerView(
                scannedURL: Binding(
                    get: {
                        // For OpenClaw: return the gateway URL
                        if selectedType == .openClaw {
                            return scannedURL
                        }

                        return nil
                },
                set: { urlString in
                    guard let urlString = urlString else { return }
                    let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
                    let lowercasedURL = trimmedURL.lowercased()
                    let isTerminalPairingURL =
                        lowercasedURL.hasPrefix("ctxgo://terminal")

                    // Check if it's a CLI terminal auth URL
                    if isTerminalPairingURL {
                        guard selectedType != .openClaw else {
                            showValidationError = true
                            errorMessage = "二维码类型不匹配：OpenClaw 请扫描 Gateway 配对链接"
                            return
                        }

                        if let pairingData = parseTerminalPairingURL(trimmedURL) {
                            terminalPublicKey = pairingData.terminalPublicKey
                            terminalMachineId = pairingData.machineId
                            terminalRuntimeServer = pairingData.runtimeServer
                            scannedAgentType = pairingData.agentType
                            showQRScanner = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                startTerminalAuth()
                            }
                        } else {
                            print("[CreateAgentView] Failed to parse terminal pairing URL: \(trimmedURL)")
                        }
                    } else {
                        if selectedType == .openClaw {
                            guard lowercasedURL.hasPrefix("wss://") || lowercasedURL.hasPrefix("ws://") else {
                                showValidationError = true
                                errorMessage = "二维码类型不匹配：OpenClaw 仅支持 ws:// 或 wss:// Gateway 链接"
                                return
                            }

                            scannedURL = trimmedURL
                            showQRScanner = false

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                addBot()
                            }
                        } else {
                            showValidationError = true
                            errorMessage = "二维码类型不匹配：请扫描 ctxgo://terminal 配对链接"
                        }
                    }
                }
            ),
            agentType: selectedType.rawValue  // 传递 Agent Type 以显示对应的提示文字
            )
        }
        .sheet(isPresented: $showTerminalConnect) {
            if let publicKey = terminalPublicKey,
               let agent = terminalAgent {
                TerminalConnectView(
                    cliPublicKey: publicKey,
                    agent: agent,
                    onAuthComplete: { token, secret in
                        Task { @MainActor in
                            print("[CreateAgent] Authorization complete, updating agent...")
                            print("[CreateAgent] Agent ID: \(agent.id)")

                            // 验证 Agent 是否还在列表中
                            if let existingAgent = homeViewModel.agents.first(where: { $0.id == agent.id }) {
                                print("[CreateAgent] ✅ Agent exists in local array")
                                print("[CreateAgent]    - ID: \(existingAgent.id)")
                                print("[CreateAgent]    - displayName: \(existingAgent.displayName)")
                            } else {
                                print("[CreateAgent] ⚠️ Agent NOT found in local array!")
                                print("[CreateAgent]    - Looking for ID: \(agent.id)")
                                print("[CreateAgent]    - Total agents: \(homeViewModel.agents.count)")
                            }

                            // 更新 Agent 配置，添加认证信息
                            var cliRelayConfig: [String: Any] = [
                                "serverURL": cliRelayServerURL,
                                "token": token,
                                "secretKey": secret.base64EncodedString()
                            ]

                            if let existingConfig = try? agent.cliRelayConfig(),
                               let machineId = existingConfig.machineId,
                               !machineId.isEmpty {
                                cliRelayConfig["machineId"] = machineId
                                print("[CreateAgent] Preserved machineId from existing config: \(machineId)")
                            }

                    if let scannedMachineId = terminalMachineId,
                       !scannedMachineId.isEmpty {
                        cliRelayConfig["machineId"] = scannedMachineId
                    }

                    if let scannedRuntimeServer = terminalRuntimeServer,
                       !scannedRuntimeServer.isEmpty {
                        cliRelayConfig["serverURL"] = scannedRuntimeServer
                    }

                            await homeViewModel.updateAgent(
                                id: agent.id,
                                config: cliRelayConfig
                            )

                            if homeViewModel.showError {
                                errorMessage = homeViewModel.errorMessage ?? "更新 Agent 失败"
                                showValidationError = true
                            } else {
                                // Register runtime device in Core with basic info from QR code
                                if let machineId = cliRelayConfig["machineId"] as? String,
                                   !machineId.isEmpty,
                                   let serverURL = cliRelayConfig["serverURL"] as? String,
                                   CoreConfig.shared.isConfigured {
                                    do {
                                        let registeredDevice = try await CoreAPIClient.shared.registerDevice(
                                            deviceId: machineId,
                                            deviceName: "Runtime (\(scannedAgentType ?? agent.type))",
                                            kind: "runtime",
                                            runtimeType: "contextgo-cli",
                                            runtimeServer: serverURL,
                                            machineId: machineId
                                        )

                                        let _ = try await CoreAPIClient.shared.bindAgentDevice(
                                            agentId: agent.id,
                                            deviceId: registeredDevice.deviceId,
                                            bindType: "runtime",
                                            bindSource: "qr"
                                        )
                                    } catch {
                                        print("[CreateAgent] ⚠️ Device registration failed: \(error.localizedDescription)")
                                    }
                                }

                                print("[CreateAgent] Agent updated with credentials")
                                showTerminalConnect = false
                                dismiss()
                            }
                        }
                    }
                )
            }
        }
        .overlay {
            if isConnecting {
                ZStack {
                    Color.primary.opacity(colorScheme == .dark ? 0.5 : 0.4)
                        .ignoresSafeArea()

                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("正在创建...")
                            .font(.headline)
                    }
                    .padding(32)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(.ultraThinMaterial)
                    )
                }
            }
        }
        .onChange(of: selectedPhotoItem) { _, newItem in
            Task {
                if let data = try? await newItem?.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        withAnimation {
                            customLogoImage = uiImage
                        }
                    }
                }
            }
        }
        .onAppear {
            let configuredRelay = CoreConfig.shared.cliRelayServerURL
            if !configuredRelay.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                cliRelayServerURL = configuredRelay
            }
        }
    }

    // MARK: - Configuration Views

    private var configurationTitle: String {
        switch selectedType {
        case .openClaw:
            return "Gateway 配置"
        case .claudeCode, .codeX, .openCode, .geminiCli:
            return "ContextGo Server 配置"
        }
    }

    @ViewBuilder
    private var configurationView: some View {
        switch selectedType {
        case .openClaw:
            openClawConfigurationView
        case .claudeCode, .codeX, .openCode, .geminiCli:
            claudeCodeConfigurationView
        default:
            EmptyView()
        }
    }

    private var openClawConfigurationView: some View {
        VStack(spacing: 16) {
            // Scan button (统一黑白灰样式)
            Button(action: {
                showQRScanner = true
            }) {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18))
                    Text("扫描终端二维码配对")
                        .font(.body)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [
                            theme.primaryText.opacity(0.9),
                            theme.primaryText.opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .foregroundColor(theme.primaryBackground)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)

            // Manual input (统一样式)
            VStack(alignment: .leading, spacing: 6) {
                Text("或手动输入配对链接")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                HStack(spacing: 8) {
                    TextField("wss://gateway.example.com/...", text: Binding(
                        get: { scannedURL ?? "" },
                        set: { scannedURL = $0.isEmpty ? nil : $0 }
                    ))
                    .autocapitalization(.none)
                    .keyboardType(.URL)
                    .padding(12)
                    .background(theme.cardBackground)
                    .cornerRadius(10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(theme.border, lineWidth: 1)
                    )
                }
            }

            // Status indicator
            if scannedURL != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("配对链接已配置")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
            }
        }
    }

    private var claudeCodeConfigurationView: some View {
        VStack(spacing: 16) {
            // Scan terminal QR button (统一黑白灰样式)
            Button(action: {
                showQRScanner = true  // Use unified QR scanner
            }) {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 18))
                    Text("扫描终端二维码配对")
                        .font(.body)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [
                            theme.primaryText.opacity(0.9),
                            theme.primaryText.opacity(0.7)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .foregroundColor(theme.primaryBackground)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)

            // Manual input
            VStack(alignment: .leading, spacing: 6) {
                Text("或手动输入配对链接")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                HStack(spacing: 8) {
                    TextField("ctxgo://terminal?xxxxx...", text: $manualAuthInput)
                        .autocapitalization(.none)
                        .keyboardType(.URL)
                        .padding(12)
                        .background(theme.cardBackground)
                        .cornerRadius(10)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(theme.border, lineWidth: 1)
                        )
                }
            }

            // Status indicator
            if terminalPublicKey != nil {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("终端密钥已配置")
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
            }
        }
    }

    // MARK: - Helper Methods

    private func handleManualAuthInput() {
        guard let pairingData = parseTerminalPairingURL(manualAuthInput) else {
            showValidationError = true
            errorMessage = "配对链接无效，请重新扫描最新二维码"
            return
        }

        terminalPublicKey = pairingData.terminalPublicKey
        terminalMachineId = pairingData.machineId
        terminalRuntimeServer = pairingData.runtimeServer
        scannedAgentType = pairingData.agentType
        startTerminalAuth()
    }

    private func parseTerminalPairingURL(_ raw: String) -> QRPairingData? {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let ctxgoPrefix = "ctxgo://terminal?"
        guard normalized.hasPrefix(ctxgoPrefix) else {
            return nil
        }

        let payloadString = String(normalized.dropFirst(ctxgoPrefix.count))
        guard let jsonData = Data(base64URLEncoded: payloadString),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let key = (json["k"] ?? json["key"]) as? String else {
            showValidationError = true
            errorMessage = "二维码格式错误，请重新生成配对二维码"
            return nil
        }

        let timestamp = (json["ts"] as? NSNumber).map { Int64(truncating: $0) }

        let pairingData = QRPairingData(
            serverURL: "",
            token: "",
            terminalPublicKey: key,
            agentType: (json["t"] ?? json["type"]) as? String,
            version: json["v"] as? Int,
            timestamp: timestamp,
            nonce: (json["n"] ?? json["nonce"]) as? String,
            machineId: (json["m"] ?? json["machineId"]) as? String,
            runtimeServer: (json["rs"] ?? json["runtimeServer"]) as? String
        )

        do {
            try pairingData.validateTerminalAuth()
        } catch {
            showValidationError = true
            errorMessage = "二维码校验失败：\(error.localizedDescription)"
            return nil
        }

        if let expected = expectedTerminalAgentType,
           let gotRaw = pairingData.agentType {
            let got = normalizeTerminalAgentType(gotRaw) ?? gotRaw.lowercased()
            guard expected == got else {
                showValidationError = true
                errorMessage = "二维码类型不匹配：当前是 \(selectedType.rawValue)，扫码内容是 \(got)"
                return nil
            }
        }

        return pairingData
    }

    private func isValidOpenClawGatewayURL(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.hasPrefix("wss://") || normalized.hasPrefix("ws://")
    }

    private func startTerminalAuth() {
        guard !isConnecting else { return }
        print("[CreateAgent] Starting terminal auth flow...")

        // 创建云端 Agent
        Task { @MainActor in
            isConnecting = true
            defer { isConnecting = false }

            // 创建 CLI Relay Agent 配置
            var config: [String: Any] = [
                "serverURL": cliRelayServerURL
            ]

            if let scannedMachineId = terminalMachineId,
               !scannedMachineId.isEmpty {
                config["machineId"] = scannedMachineId
            }
            if let scannedRuntimeServer = terminalRuntimeServer,
               !scannedRuntimeServer.isEmpty {
                config["serverURL"] = scannedRuntimeServer
            }
            // 调用云端 API 创建 Agent
            let happyAgentKey = selectedType.rawValue
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")

            let newAgent = await homeViewModel.createAgent(
                name: "\(happyAgentKey)-\(UUID().uuidString.prefix(8))",
                displayName: effectiveBotName,
                description: "通过 \(selectedType.rawValue) 连接",
                avatar: selectedType.logoImageName,
                type: cloudAgentType(for: selectedType),
                config: config
            )

            // 检查是否创建成功
            if let agent = newAgent {
                terminalAgent = agent  // 直接存储 Agent 对象
                print("[CreateAgent] Agent created: \(agent.displayName) (ID: \(agent.id))")

                // 显示终端连接界面
                showTerminalConnect = true
            } else {
                // 创建失败
                errorMessage = homeViewModel.errorMessage ?? "创建 Agent 失败"
                showValidationError = true
                print("[CreateAgent] Failed to create agent")
            }
        }
    }

    private func addBot() {
        guard !isConnecting else { return }

        if selectedType == .openClaw, !isValidOpenClawGatewayURL(scannedURL) {
            showValidationError = true
            errorMessage = "OpenClaw 仅支持 ws:// 或 wss:// Gateway 链接"
            return
        }

        Task { @MainActor in
            isConnecting = true
            defer { isConnecting = false }

            // 根据 Agent 类型创建配置
            let config: [String: Any]
            if selectedType == .openClaw {
                config = [
                    "gatewayURL": scannedURL ?? ""
                ]
            } else {
                var cliRelayConfig: [String: Any] = [
                    "serverURL": cliRelayServerURL
                ]
                config = cliRelayConfig
            }

            // 调用云端 API 创建 Agent
            let newAgent = await homeViewModel.createAgent(
                name: "agent-\(UUID().uuidString.prefix(8))",
                displayName: effectiveBotName,
                description: "通过 \(selectedType.rawValue) 连接",
                avatar: selectedType.logoImageName,
                type: cloudAgentType(for: selectedType),
                config: config
            )

            if let newAgent = newAgent {
                print("[CreateAgent] Agent added successfully")

                // 延迟关闭
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    dismiss()
                }
            } else {
                errorMessage = homeViewModel.errorMessage ?? "创建 Agent 失败"
                showValidationError = true
                print("[CreateAgent] Failed to create agent")
            }
        }
    }

    /// 自动恢复 OpenClaw 会话列表（最多 10 个）
    private func restoreOpenClawSessions(agent: CloudAgent) async {
        do {
            // Step 1: 获取 Gateway URL 并连接
            let config = try agent.openClawConfig()
            let gatewayURL = config.wsURL

            guard !gatewayURL.isEmpty else {
                print("[CreateAgent] ❌ Empty gateway URL")
                return
            }

            let connectionManager = ConnectionManager.shared
            let client = connectionManager.getClient(for: agent.id, gatewayURL: gatewayURL)

            // 等待连接（最多 5 秒）
            if !client.isConnected {
                print("[CreateAgent] 📡 Connecting to Gateway...")
                client.connect()
                for _ in 0..<50 {
                    if client.isConnected {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
                }
            }

            guard client.isConnected else {
                print("[CreateAgent] ❌ Failed to connect to Gateway")
                return
            }

            // Step 2: 获取远程会话列表
            print("[CreateAgent] 🔄 Fetching remote sessions...")
            let response = try await client.fetchSessionsList(limit: 200, activeMinutes: 525600)

            guard let remoteSessions = response.sessions else {
                print("[CreateAgent] ⚠️ No sessions in response")
                return
            }

            print("[CreateAgent] 📬 Received \(remoteSessions.count) remote sessions")

            // Step 3: 过滤 operator 格式的会话，按时间排序，最多取 10 个
            let operatorSessions = remoteSessions
                .filter { $0.key.hasPrefix("agent:main:operator:") }
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }  // 按时间降序
                .prefix(10)  // 最多 10 个

            print("[CreateAgent] ✅ Restoring \(operatorSessions.count) operator sessions")

            // Step 4: 创建到本地数据库
            let sessionRepository = LocalSessionRepository.shared

            for remoteSession in operatorSessions {
                // 从 sessionKey 提取 suffix
                let suffix = remoteSession.key.replacingOccurrences(of: "agent:main:operator:", with: "")

                // 生成 sessionId
                let sessionId: String
                if let remoteSessionId = remoteSession.sessionId, !remoteSessionId.isEmpty {
                    sessionId = remoteSessionId
                } else {
                    sessionId = "session_\(suffix)"
                }

                // 生成时间
                let lastMessageTime: Date
                if let updatedAt = remoteSession.updatedAt {
                    lastMessageTime = Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000.0)
                } else {
                    lastMessageTime = Date()
                }

                // 创建 metadata
                var metadata: [String: Any] = [
                    "sessionKey": remoteSession.key
                ]
                if let remoteSessionId = remoteSession.sessionId, !remoteSessionId.isEmpty {
                    metadata["remoteSessionId"] = remoteSessionId
                }

                // 创建 ContextGoSession
                var session = ContextGoSession(
                    id: sessionId,
                    agentId: agent.id,
                    title: remoteSession.displayName ?? "Chat",
                    preview: "",
                    tags: ["openclaw"],
                    createdAt: lastMessageTime,
                    updatedAt: lastMessageTime,
                    lastMessageTime: lastMessageTime,
                    isActive: false,
                    isPinned: false,
                    isArchived: false,
                    channelMetadata: nil,
                    messagesCachePath: SessionStorageLayout.messagesRelativePath(agentId: agent.id, sessionId: sessionId),
                    syncStatus: .synced,
                    lastSyncAt: Date()
                )

                session.setChannelMetadata(metadata)

                // 保存到数据库
                try await sessionRepository.createSession(session)
                print("[CreateAgent] ✨ Restored session: \(remoteSession.key)")
            }

            print("[CreateAgent] ✅ Session restoration complete: \(operatorSessions.count) sessions")

        } catch {
            print("[CreateAgent] ❌ Session restoration failed: \(error)")
        }
    }

    func handleCreate() {
        guard isFormValid else {
            withAnimation {
                showValidationError = true
                errorMessage = "请完成必要的配置"
            }
            return
        }

        switch selectedType {
        case .openClaw:
            // Direct add for OpenClaw
            addBot()

        case .claudeCode, .codeX, .openCode, .geminiCli:
            // Check if terminal auth is needed
            if !manualAuthInput.isEmpty {
                handleManualAuthInput()
            } else if terminalPublicKey != nil {
                startTerminalAuth()
            } else {
                // Create without terminal auth (can pair later)
                addBot()
            }

        default:
            break
        }
    }
}

// MARK: - Agent Type Card Component

struct AgentTypeCard: View {
    let type: AgentType
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 40, height: 40)
                            .overlay(
                                Circle()
                                    .stroke(theme.border.opacity(0.7), lineWidth: 1)
                            )

                        // Logo - fill the circle
                        if let logoImageName = type.logoImageName {
                            Image(logoImageName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 40, height: 40)
                                .clipShape(Circle())
                                .grayscale(type.isSupported ? 0 : 0.8)
                        } else {
                            Image(systemName: type.icon)
                                .font(.body)
                                .foregroundColor(type.color)
                                .grayscale(type.isSupported ? 0 : 0.8)
                        }
                    }

                    Text(type.rawValue)
                        .font(.caption)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundColor(
                            type.isSupported
                            ? (isSelected ? theme.primaryText : theme.secondaryText)
                            : theme.tertiaryText
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)

                // "Soon" badge on card's top-right corner
                if !type.isSupported {
                    Text("Soon")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.orange))
                        .offset(x: -4, y: 4)
                }
            }
            .background(
                isSelected ? type.color.opacity(0.1) : theme.cardBackground
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? type.color.opacity(0.5) : theme.border,
                        lineWidth: isSelected ? 2 : 1
                    )
            )
            .opacity(type.isSupported ? 1.0 : 0.7)
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Preview

#Preview {
    CreateAgentView()
        .environmentObject(HomeViewModel())
        .preferredColorScheme(.dark)
}
