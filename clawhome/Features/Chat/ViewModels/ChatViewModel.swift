//
//  ChatViewModel.swift
//  contextgo
//
//  Chat screen ViewModel
//

import Foundation
import Combine
import UIKit

@MainActor
final class ClawHomeLogStore: ObservableObject {
    static let shared = ClawHomeLogStore()

    @Published private(set) var entries: [String] = []
    private let limit = 200

    private init() {}

    func append(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        entries.append("[\(timestamp)] \(message)")
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    func clear() {
        entries.removeAll()
    }

    var exportText: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"
        let header = [
            "App: 爪家 / clawhome",
            "App 版本: \(version)",
            "Build: \(build)",
            "",
            "日志:",
        ]
        return (header + entries).joined(separator: "\n")
    }
}

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var otherChannelActive: Bool = false  // New: indicates other channels are active
    @Published var activeChannels: Set<String> = []  // New: which channels are active
    @Published var isConnected: Bool = false  // Connection status
    @Published var isConnecting: Bool = false  // Connecting status
    @Published var hasActiveRuns: Bool = false  // Stop button state (runQueue not empty)
    @Published var currentThinkingLevel: String = "off"
    @Published var connectionDiagnostics: [String] = []

    var latestConnectionDiagnostic: String? {
        connectionDiagnostics.last
    }

    private func appendConnectionDiagnostic(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        connectionDiagnostics.append("[\(timestamp)] \(message)")
        ClawHomeLogStore.shared.append(message)
        if connectionDiagnostics.count > 80 {
            connectionDiagnostics.removeFirst(connectionDiagnostics.count - 80)
        }
    }

    var connectionDiagnosticsSummary: String {
        connectionDiagnostics.joined(separator: "\n")
    }

    private func presentError(_ message: String, log: String? = nil) {
        if let log, !log.isEmpty {
            appendConnectionDiagnostic(log)
        } else {
            appendConnectionDiagnostic(message)
        }
        errorMessage = message
        showError = true
    }

    // Recording state
    @Published var inputMode: InputMode = .text  // 输入模式
    @Published var recordingState: RecordingState = .idle
    @Published var recordingDuration: TimeInterval = 0
    @Published var isHoldingSpeakButton: Bool = false  // 是否正在按住说话
    @Published var isRecognizingAudio: Bool = false  // ✅ 是否正在识别音频（录音已停止但 ASR 还在处理）
    @Published var isMeetingRecording: Bool = false  // ✅ 是否在录音纪要模式
    @Published var meetingPhase: MeetingRecordingPhase = .ready  // ✅ 录音纪要阶段

    // Real-time ASR
    @Published var realtimeTranscript: String = ""  // 实时转写文字
    @Published var partialTranscript: String = ""   // 部分识别结果

    // Toolbar state
    @Published var showFilePicker = false
    @Published var showImagePicker = false
    @Published var showMoreOptions = false

    // Slash commands
    @Published var showCommandPalette: Bool = false
    @Published var filteredCommands: [SlashCommand] = []

    // Tool execution tracking (NEW)
    @Published var activeTools: [String: ToolExecution] = [:]  // Current run snapshot: toolId -> ToolExecution
    @Published var agentState: AgentState = .idle  // Agent lifecycle state

    // Message sync tracking (NEW)
    private var processedMessageIds: Set<String> = []  // Track processed message IDs to prevent duplicates
    private var lastSyncTimestamp: TimeInterval = 0  // Last sync timestamp for incremental sync
    private var isSyncing: Bool = false  // Prevent concurrent sync operations
    private var wasConnected: Bool = false

    // Agent profile (CloudAgent from backend)
    var agent: CloudAgent?

    /// UI layer reads CloudAgent directly.
    var bot: CloudAgent? { agent }

    // MARK: - Session Management
    private var sessionId: String?
    private let sessionRepository: LocalSessionRepository

    // MARK: - Agent State Enum (NEW)
    enum AgentState: Equatable {
        case idle
        case thinking  // Agent started (lifecycle start)
        case responding  // Agent sending text
        case stopped(String?)  // Run aborted/stopped with optional reason
        case error(String)  // Agent encountered error
        case compacting(String)  // Agent compacting memory (phase/status)
    }

    // MARK: - Dependencies
    let clawdBotClient: OpenClawClient
    let chatPlugin: ChatAgentPlugin
    private let realtimeAudioManager: RealtimeAudioManager
    private let meetingRecordingManager: MeetingRecordingManager
    private let fileASRService: FileASRService
    private var cancellables = Set<AnyCancellable>()
    private var currentStreamingMessageId: UUID?
    private var currentThinkingMessageId: UUID?
    private var runToMessageId: [String: UUID] = [:]
    private var toolsByRunId: [String: [String: ToolExecution]] = [:]
    private var runsWithAgentTextStream: Set<String> = []
    private let sessionKey: String  // Fixed sessionKey for consistent history
    var currentSessionKey: String { sessionKey }  // Expose for ThinkingLevel UI
    var currentStorageSessionId: String? { resolvedSessionIdForStorage() }
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var isFinishingRecording = false  // ✅ 防止重复调用 finishHoldToSpeakRecording

    // MARK: - Smooth Typing Animation
    private var characterQueue: [Character] = []  // 字符缓冲队列
    private var typingTimer: Timer?  // 逐字输出定时器
    // 打字速度：0.015秒/字符 = 67字符/秒（中英文混合最佳速度）
    // 可调范围：0.01-0.03秒，越小越快，越大越慢
    private let typingSpeed: TimeInterval = 0.015
    private var emptyQueueCount: Int = 0  // 队列连续为空的次数

    // MARK: - Unique instance ID to prevent callback conflicts
    private let viewModelId = UUID()

    // MARK: - Deinitialization
    deinit {
        print("🗑️ [ChatViewModel \(viewModelId)] Deinitializing")
        // Note: Callbacks are cleared when ChatView disappears via onDisappear
    }

    // MARK: - Initialization
    init(
        agent: CloudAgent? = nil,
        sessionId: String? = nil,
        sessionKey overrideSessionKey: String? = nil,  // 外部预先解析的 sessionKey
        connectionManager: ConnectionManager = .shared,
        realtimeAudioManager: RealtimeAudioManager = .shared,
        meetingRecordingManager: MeetingRecordingManager = .shared,
        fileASRService: FileASRService = .shared,
        sessionRepository: LocalSessionRepository? = nil
    ) {
        self.agent = agent
        self.sessionId = sessionId
        self.sessionRepository = sessionRepository ?? LocalSessionRepository.shared

        // ✅ Get agent-specific OpenClawClient from ConnectionManager
        let gatewayURL: String?
        let gatewayToken: String?
        if let agent = agent {
            // Extract gatewayURL from config
            if agent.type == "openclaw", let config = try? agent.openClawConfig() {
                gatewayURL = config.wsURL
                gatewayToken = config.token
            } else {
                gatewayURL = nil
                gatewayToken = nil
            }

            self.clawdBotClient = connectionManager.getClient(for: agent.id, gatewayURL: gatewayURL, token: gatewayToken)
            print("[ChatViewModel] 📋 Using dedicated client for agent: \(agent.displayName) at \(gatewayURL ?? "default")")
        } else {
            gatewayURL = nil
            gatewayToken = nil
            // Fallback: create a default client if no agent is provided
            let defaultURL = URL(string: CoreConfig.shared.openClawGatewayURL)!
            self.clawdBotClient = OpenClawClient(url: defaultURL)
            print("[ChatViewModel] ⚠️ No agent provided, using default client")
        }

        self.chatPlugin = ChatAgentPluginRegistry.resolve(agent: agent)
        self.realtimeAudioManager = realtimeAudioManager
        self.meetingRecordingManager = meetingRecordingManager
        self.fileASRService = fileASRService

        // ✅ Use session-specific sessionKey:
        let botId = agent?.id ?? "default"
        self.sessionKey = overrideSessionKey ?? "agent:main:operator:\(botId)"
        print("[ChatViewModel] 📋 Using sessionKey: \(self.sessionKey) for agent: \(agent?.displayName ?? "默认")")

        // Set initial connection state
        self.isConnected = clawdBotClient.isConnected
        self.isConnecting = clawdBotClient.connectionState == .connecting
        self.wasConnected = clawdBotClient.isConnected
        appendConnectionDiagnostic("使用 HTTP IronClaw 客户端：\(self.clawdBotClient.isConnected ? "已连接" : "待连接")")
        if let gateway = gatewayURL, !gateway.isEmpty {
            appendConnectionDiagnostic("当前网关地址：\(gateway)")
        }
        if let gatewayToken, !gatewayToken.isEmpty {
            appendConnectionDiagnostic("当前网关 Token 已装载（长度 \(gatewayToken.count)）")
        }

        if agent == nil {
            appendConnectionDiagnostic("当前没有专用 agent 配置，回退到默认 IronClaw 地址：\(CoreConfig.shared.openClawGatewayURL)")
        }

        setupStreamingCallbacks()
        setupConnectionBindings()
        setupMeetingRecordingBindings()

        // ✅ Auto-connect when ChatViewModel is created
        if !clawdBotClient.isConnected && clawdBotClient.connectionState != .connecting {
            appendConnectionDiagnostic("准备连接 HTTP 主链路。旧 relay / WebSocket 状态不会决定聊天是否可用。")
            clawdBotClient.connect()
        }

        Task {
            await ensureSession()
            await loadMessagesFromLocalStorage()
            await replayBufferedMessageIfNeeded()
            await syncMessagesFromIronClaw()
        }
    }

    // MARK: - Setup
    private func setupConnectionBindings() {
        // Monitor connection state
        clawdBotClient.$isConnected
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isConnected in
                guard let self = self else { return }
                let previous = self.wasConnected
                self.wasConnected = isConnected
                self.isConnected = isConnected
                self.appendConnectionDiagnostic(isConnected ? "HTTP 聊天主链路已连接" : "HTTP 聊天主链路已断开")

                if isConnected && !previous {
                    Task { [weak self] in
                        await self?.syncMessagesFromIronClaw()
                    }
                }
            }
            .store(in: &cancellables)

        clawdBotClient.$connectionState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.isConnecting = state == .connecting
                self?.appendConnectionDiagnostic("HTTP 客户端状态变更：\(String(describing: state))")
            }
            .store(in: &cancellables)
    }

    private func setupMeetingRecordingBindings() {
        // Bind meeting recording duration to recordingDuration
        meetingRecordingManager.$recordingDuration
            .receive(on: DispatchQueue.main)
            .sink { [weak self] duration in
                guard let self = self, self.isMeetingRecording else { return }
                self.recordingDuration = duration
            }
            .store(in: &cancellables)
    }

    private func setupStreamingCallbacks() {
        print("📝 [ChatViewModel \(viewModelId)] Setting up streaming callbacks")
        chatPlugin.bind(client: clawdBotClient, viewModel: self)
    }

    func handlePluginEvent(_ event: ChatAgentPluginEvent) {
        switch event {
        case .streamDelta(let delta):
            guard currentStreamingMessageId != nil else {
                print("⚠️ [ChatViewModel \(viewModelId)] Ignoring delta - no active stream")
                return
            }
            print("📨 [ChatViewModel \(viewModelId)] Received delta callback")
            appendStreamingText(delta)

        case .thinkingDelta(let thinking):
            appendThinkingText(thinking)

        case .streamComplete:
            guard currentStreamingMessageId != nil else {
                print("⚠️ [ChatViewModel \(viewModelId)] Ignoring complete - no active stream")
                return
            }
            print("✅ [ChatViewModel \(viewModelId)] Stream complete callback")
            finalizeStreamingMessage()

        case .streamError(let error):
            print("❌ [ChatViewModel \(viewModelId)] Stream error callback: \(error)")
            handleStreamingError(error)

        case .runAccepted(let runId):
            bindCurrentStreamingMessage(to: runId)

        case .chatState(let event):
            print("🧾 [ChatViewModel \(viewModelId)] Chat state: \(event.state), runId: \(event.runId), reason: \(event.stopReason ?? "nil")")
            handleChatStateEvent(event)

        case .otherChannelActivity(let channels, let isActive):
            print("📡 [ChatViewModel \(viewModelId)] Channel activity callback")
            handleOtherChannelActivity(channels: channels, isActive: isActive)

        case .toolStart(let runId, let toolId, let toolName, let input):
            print("🔧 [ChatViewModel \(viewModelId)] Tool start: \(toolName) (run: \(runId), id: \(toolId))")
            handleToolStart(runId: runId, toolId: toolId, toolName: toolName, input: input)

        case .toolUpdate(let runId, let toolId, let partialOutput):
            print("🔧 [ChatViewModel \(viewModelId)] Tool update: \(toolId) in run \(runId)")
            handleToolUpdate(runId: runId, toolId: toolId, partialOutput: partialOutput)

        case .toolResult(let runId, let toolId, let output, let error):
            print("🔧 [ChatViewModel \(viewModelId)] Tool result: \(toolId) in run \(runId)")
            handleToolResult(runId: runId, toolId: toolId, output: output, error: error)

        case .lifecycleStart(let runId):
            print("🧠 [ChatViewModel \(viewModelId)] Agent lifecycle start (thinking), runId: \(runId)")
            bindCurrentStreamingMessage(to: runId)
            agentState = .thinking

        case .lifecycleEnd(let runId):
            print("✅ [ChatViewModel \(viewModelId)] Agent lifecycle end, runId: \(runId)")
            finalizeThinkingMessage(for: runId)
            agentState = .idle
            finalizeStreamingMessage(for: runId)
            clearRunState(runId)

        case .lifecycleError(let runId, let error):
            print("❌ [ChatViewModel \(viewModelId)] Agent lifecycle error: \(error), runId: \(runId)")
            finalizeThinkingMessage(for: runId)
            if case .stopped = agentState {
                // Preserve explicit stopped status from chat.aborted channel.
            } else if let mappedStopReason = mapStopReasonCode(error) {
                agentState = .stopped(mappedStopReason)
            } else {
                agentState = .error(error)
            }
            clearRunState(runId)

        case .compaction(let event):
            print("🗜️ [ChatViewModel \(viewModelId)] Compaction event: \(event.phase), runId: \(event.runId)")
            if event.phase == "start" {
                agentState = .compacting("正在整理上下文…")
            } else if event.phase == "end" {
                agentState = .compacting("上下文整理完成")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    if case .compacting = self.agentState {
                        self.agentState = self.hasActiveRuns ? .responding : .idle
                    }
                }
            }

        case .runQueueChanged(let hasActiveRuns):
            print("🛑 [ChatViewModel \(viewModelId)] Run queue changed: hasActiveRuns=\(hasActiveRuns)")
            self.hasActiveRuns = hasActiveRuns
        }
    }

    // MARK: - Session Management

    /// 确保 session 存在（创建新 session 如果不存在）
    /// ✅ 修复：IronClaw 使用固定 session ID 避免重复创建
    private func ensureSession() async {
        guard let agent = agent else { return }

        let targetSessionId = sessionId ?? defaultOpenClawSessionId(agentId: agent.id)

        do {
            if let _ = try await sessionRepository.getSession(id: targetSessionId) {
                sessionId = targetSessionId
                print("✅ Reusing existing session: \(targetSessionId)")
                return
            }
        } catch {
            print("[ChatViewModel] Session lookup failed, will create: \(error)")
        }

        let metadata: [String: Any] = [
            "sessionKey": sessionKey
        ]

        var session = ContextGoSession(
            id: targetSessionId,
            agentId: agent.id,
            title: "与 \(agent.displayName) 的对话",
            preview: "",
            tags: ["openclaw"],
            createdAt: Date(),
            updatedAt: Date(),
            lastMessageTime: Date(),
            isActive: false,
            isPinned: false,
            isArchived: false,
            channelMetadata: nil,
            messagesCachePath: SessionStorageLayout.messagesRelativePath(agentId: agent.id, sessionId: targetSessionId),
            syncStatus: .localOnly,
            lastSyncAt: nil
        )

        session.setChannelMetadata(metadata)

        do {
            try await sessionRepository.createSession(session)
            sessionId = targetSessionId
            print("✅ Created new session: \(targetSessionId)")
        } catch {
            print("❌ Failed to create session: \(error)")
        }
    }

    private func resolvedSessionIdForStorage() -> String? {
        if let sessionId {
            return sessionId
        }
        guard let agent = agent else {
            return nil
        }
        return defaultOpenClawSessionId(agentId: agent.id)
    }

    private func defaultOpenClawSessionId(agentId: String) -> String {
        let prefix = "agent:main:operator:"
        if sessionKey.hasPrefix(prefix) {
            let suffix = String(sessionKey.dropFirst(prefix.count))
            if !suffix.isEmpty {
                return "session_\(suffix)"
            }
        }
        return "session_default_\(agentId)"
    }

    private func replayBufferedMessageIfNeeded() async {
        guard let bufferedMessage = clawdBotClient.retrieveBufferedMessage(for: sessionKey) else {
            return
        }
        let messageText = bufferedMessage.fullText
        guard !messageText.isEmpty else {
            clawdBotClient.clearBufferedMessage(for: sessionKey)
            return
        }

        let bufferedChatMessage = ChatMessage(
            text: messageText,
            isUser: false,
            isStreaming: false
        )
        messages.append(bufferedChatMessage)
        persistChatMessage(bufferedChatMessage)
        clawdBotClient.clearBufferedMessage(for: sessionKey)
    }

    private func loadMessagesFromLocalStorage() async {
        guard let storageSessionId = resolvedSessionIdForStorage() else { return }

        do {
            let cachedMessages = try await sessionRepository.getCachedMessages(sessionId: storageSessionId, limit: nil, offset: nil)
            if !cachedMessages.isEmpty {
                messages = cachedMessages.map { sessionMessage in
                    ChatMessage(
                        id: stableUUID(for: sessionMessage.id),
                        text: sessionMessage.content,
                        isUser: sessionMessage.role == .user,
                        timestamp: sessionMessage.timestamp,
                        isStreaming: false,
                        toolExecutions: decodeToolExecutions(from: sessionMessage),
                        lifecycleState: decodeLifecycleState(from: sessionMessage),
                        errorInfo: decodeErrorInfo(from: sessionMessage)
                    )
                }
                messages.sort { $0.timestamp < $1.timestamp }
                return
            }
        } catch {
            print("[ChatViewModel] Failed to load cached session messages: \(error)")
        }
    }

    private func persistChatMessage(_ message: ChatMessage) {
        guard !message.isStreaming,
              let storageSessionId = resolvedSessionIdForStorage() else {
            return
        }

        let sessionMessage = buildSessionMessage(from: message, sessionId: storageSessionId)

        Task {
            do {
                try await sessionRepository.cacheMessage(sessionMessage, to: storageSessionId)
            } catch {
                print("[ChatViewModel] Failed to persist message to session store: \(error)")
            }
        }
    }

    private func persistIronClawSnapshot(_ snapshot: [ChatMessage]) async {
        guard let storageSessionId = resolvedSessionIdForStorage() else {
            return
        }

        do {
            try await sessionRepository.clearMessageCache(sessionId: storageSessionId)
            for message in snapshot where !message.isStreaming {
                let sessionMessage = buildSessionMessage(from: message, sessionId: storageSessionId)
                try await sessionRepository.cacheMessage(sessionMessage, to: storageSessionId)
            }
        } catch {
            print("[ChatViewModel] Failed to persist IronClaw snapshot: \(error)")
        }
    }

    private func buildSessionMessage(from message: ChatMessage, sessionId: String) -> SessionMessage {
        let toolExecutions = message.toolExecutions
        let toolCalls = toolExecutions?.map {
            ToolCall(id: $0.id, name: $0.name, input: $0.input)
        }
        let toolResults = toolExecutions?.compactMap { tool -> ToolResult? in
            if tool.output == nil, tool.error == nil {
                return nil
            }
            return ToolResult(toolCallId: tool.id, output: tool.output, error: tool.error)
        }
        let metadata = buildSessionMessageMetadata(from: message)

        return SessionMessage(
            id: message.id.uuidString,
            sessionId: sessionId,
            timestamp: message.timestamp,
            role: message.isUser ? .user : .assistant,
            content: message.text,
            toolCalls: toolCalls,
            toolResults: toolResults,
            metadata: metadata
        )
    }

    private func buildSessionMessageMetadata(from message: ChatMessage) -> [String: AnyCodable]? {
        var metadata: [String: AnyCodable] = ["source": AnyCodable("ios-chat-viewmodel")]

        if let toolExecutions = message.toolExecutions,
           let encoded = encodeJSON(toolExecutions) {
            metadata["chatToolExecutions"] = AnyCodable(encoded)
        }

        if let lifecycle = message.lifecycleState,
           let encoded = encodeJSON(lifecycle) {
            metadata["chatLifecycleState"] = AnyCodable(encoded)
        }

        if let errorInfo = message.errorInfo,
           let encoded = encodeJSON(errorInfo) {
            metadata["chatErrorInfo"] = AnyCodable(encoded)
        }

        return metadata.isEmpty ? nil : metadata
    }

    private func decodeToolExecutions(from message: SessionMessage) -> [ToolExecution]? {
        if let raw = message.metadata?["chatToolExecutions"]?.value as? String,
           let decoded: [ToolExecution] = decodeJSON(raw) {
            return decoded
        }

        guard let calls = message.toolCalls, !calls.isEmpty else {
            return nil
        }
        let resultByCallId: [String: ToolResult] = Dictionary(uniqueKeysWithValues: (message.toolResults ?? []).map { ($0.toolCallId, $0) })
        return calls.map { call in
            let result = resultByCallId[call.id]
            return ToolExecution(
                id: call.id,
                runId: nil,
                name: call.name,
                phase: .result,
                input: call.input,
                output: result?.output,
                error: result?.error,
                startTime: message.timestamp,
                endTime: message.timestamp
            )
        }
    }

    private func decodeLifecycleState(from message: SessionMessage) -> AgentLifecycleState? {
        guard let raw = message.metadata?["chatLifecycleState"]?.value as? String else {
            return nil
        }
        let decoded: AgentLifecycleState? = decodeJSON(raw)
        return decoded
    }

    private func decodeErrorInfo(from message: SessionMessage) -> AgentErrorInfo? {
        guard let raw = message.metadata?["chatErrorInfo"]?.value as? String else {
            return nil
        }
        let decoded: AgentErrorInfo? = decodeJSON(raw)
        return decoded
    }

    private func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func decodeJSON<T: Decodable>(_ raw: String) -> T? {
        guard let data = raw.data(using: .utf8) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(T.self, from: data)
    }

    private func clearLocalSessionMessages() async {
        if let storageSessionId = resolvedSessionIdForStorage() {
            do {
                try await sessionRepository.clearMessageCache(sessionId: storageSessionId)
            } catch {
                print("[ChatViewModel] Failed to clear session cache: \(error)")
            }
        }
    }

    // MARK: - Actions

    // MARK: - Slash Commands

    func updateCommandPalette() {
        // 检测是否输入了斜杠
        if inputText.hasPrefix("/") {
            let query = String(inputText.dropFirst()) // 去掉斜杠
            filteredCommands = SlashCommand.search(query: query)
            showCommandPalette = !filteredCommands.isEmpty || query.isEmpty
        } else {
            showCommandPalette = false
            filteredCommands = []
        }
    }

    func executeCommand(_ command: SlashCommand) {
        // 隐藏命令面板
        showCommandPalette = false
        inputText = ""

        // 执行命令
        switch command.action {
        case .local(let localAction):
            // 本地执行的命令
            executeLocalCommand(localAction)

        case .sendToAI(let commandText):
            // 发送给 AI 的命令
            sendCommandToAI(commandText)
        }
    }

    private func executeLocalCommand(_ action: SlashCommand.CommandAction.LocalAction) {
        switch action {
        case .clearSession:
            clearSession()
        }
    }

    private func sendCommandToAI(_ commandText: String) {
        // 将命令作为普通消息发送给 AI
        print("📤 发送命令给 AI: \(commandText)")

        // 添加用户消息显示命令
        let userMessage = ChatMessage(text: commandText, isUser: true)
        messages.append(userMessage)

        persistChatMessage(userMessage)

        // 发送给 AI
        Task {
            await sendToAI(commandText)
        }
    }

    private func newSession() {
        // 保存当前会话
        for message in messages where !message.isStreaming {
            persistChatMessage(message)
        }

        // 清空当前消息
        messages.removeAll()

        // 显示欢迎消息
        let welcomeText = agent != nil
            ? "新会话已创建。我是 \(agent!.displayName)，\(agent!.description ?? "")有什么可以帮你的吗？"
            : "新会话已创建。有什么可以帮你的吗？"

        let welcomeMessage = ChatMessage(
            text: welcomeText,
            isUser: false
        )
        messages.append(welcomeMessage)

        print("✅ [Command] 新建会话")
    }

    private func clearSession() {
        // 清空消息（不保存到历史）
        messages.removeAll()

        // 清空本地历史
        Task {
            await clearLocalSessionMessages()
        }

        // 显示清空确认消息
        let confirmMessage = ChatMessage(
            text: "当前会话已清空。",
            isUser: false
        )
        messages.append(confirmMessage)

        print("✅ [Command] 清空会话")
    }

    func sendMessage(attachments: [AttachmentItem] = []) {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty else {
            return
        }

        // Check connection status
        guard isConnected else {
            presentError(
                "未连接到 IronClaw HTTP 主链路，无法发送消息",
                log: "发送被阻止：HTTP 主链路未连接"
            )
            return
        }

        let userMessage = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""

        // Send to AI with attachments (will add user message inside)
        Task {
            await sendToAI(userMessage, attachments: attachments)
        }
    }

    func clearChat() {
        Task {
            await clearLocalSessionMessages()
        }

        messages.removeAll()
        let clearMessage = ChatMessage(
            text: "对话已清空。有什么可以帮你的吗？",
            isUser: false
        )
        messages.append(clearMessage)

        // Save clear message
        persistChatMessage(clearMessage)
    }

    /// Send a message directly to AI (used by skill installation, etc.)
    func sendDirectMessage(_ message: String) async {
        guard !message.isEmpty else { return }
        await sendToAI(message, attachments: [])
    }

    // MARK: - Private Methods
    private func sendToAI(_ message: String, attachments: [AttachmentItem] = []) async {
        guard !isSending else { return }

        isSending = true

        do {
            var finalMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
            var outboundAttachments: [OpenClawAttachment] = []
            var uploadedAttachments: [AttachmentUploadResult] = []

            if !attachments.isEmpty {
                let prepared = try await prepareUploadedAttachments(attachments)
                outboundAttachments = prepared.outbound
                uploadedAttachments = prepared.uploads
                finalMessage = appendAttachmentReferencesIfNeeded(baseMessage: finalMessage, uploads: uploadedAttachments)
            }

            guard !finalMessage.isEmpty || !outboundAttachments.isEmpty else {
                throw NSError(
                    domain: "ChatViewModel",
                    code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "没有可发送的内容"]
                )
            }

            // Add user message to UI (with attachments protocol)
            let userChatMessage = ChatMessage(text: finalMessage, isUser: true)
            messages.append(userChatMessage)
            persistChatMessage(userChatMessage)

            // Update session activity
            if let sessionId = sessionId {
                do {
                    if var session = try await sessionRepository.getSession(id: sessionId) {
                        session.lastMessageTime = Date()
                        session.preview = message.prefix(100).description
                        session.updatedAt = Date()
                        try await sessionRepository.updateSession(session)
                    }
                } catch {
                    print("❌ Failed to update session: \(error)")
                }
            }

            // Create placeholder for AI response
            let aiMessageId = UUID()
            currentStreamingMessageId = aiMessageId
            let aiMessage = ChatMessage(
                id: aiMessageId,
                text: "",
                isUser: false,
                isStreaming: true
            )
            messages.append(aiMessage)

            // Send message with structured attachments (content as data URL base64)
            let runId = try await clawdBotClient.sendMessage(
                finalMessage,
                sessionKey: sessionKey,
                attachments: outboundAttachments
            )
            bindCurrentStreamingMessage(to: runId)

        } catch {
            handleError(error)
            // Remove streaming placeholder
            if let id = currentStreamingMessageId {
                messages.removeAll { $0.id == id }
                if let boundRunId = runToMessageId.first(where: { $0.value == id })?.key {
                    clearRunState(boundRunId)
                }
                currentStreamingMessageId = nil
            }
        }

        isSending = false
    }

    private func prepareUploadedAttachments(_ attachments: [AttachmentItem]) async throws -> (outbound: [OpenClawAttachment], uploads: [AttachmentUploadResult]) {
        var outbound: [OpenClawAttachment] = []
        let uploads: [AttachmentUploadResult] = []

        for attachment in attachments {
            let dataURL = "data:\(attachment.mimeType);base64,\(attachment.fileData.base64EncodedString())"
            outbound.append(
                OpenClawAttachment(
                    type: openClawAttachmentType(from: attachment.type),
                    mimeType: attachment.mimeType,
                    fileName: attachment.fileName,
                    content: dataURL
                )
            )
        }

        return (outbound, uploads)
    }

    private func appendAttachmentReferencesIfNeeded(baseMessage: String, uploads: [AttachmentUploadResult]) -> String {
        guard !uploads.isEmpty else { return baseMessage }

        let normalizedBase = baseMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        let header = "附件引用 (ctxgo://):"
        let lines = uploads.map { "- \($0.fileName): \($0.attachmentUri)" }
        let refs = ([header] + lines).joined(separator: "\n")

        if normalizedBase.isEmpty {
            return "请结合附件内容回答。\n\(refs)"
        }
        return "\(normalizedBase)\n\n\(refs)"
    }

    private func openClawAttachmentType(from type: AttachmentType) -> String {
        switch type {
        case .image:
            return "image"
        case .video:
            return "video"
        case .audio:
            return "audio"
        case .file:
            return "file"
        }
    }

    private func bindCurrentStreamingMessage(to runId: String) {
        guard let currentStreamingMessageId else { return }
        if runToMessageId[runId] == nil {
            runToMessageId[runId] = currentStreamingMessageId
        }
        if let runTools = toolsByRunId[runId] {
            activeTools = runTools
            updateStreamingMessageWithTools(runId: runId)
        }
    }

    private func clearRunState(_ runId: String) {
        runToMessageId.removeValue(forKey: runId)
        toolsByRunId.removeValue(forKey: runId)
        runsWithAgentTextStream.remove(runId)
        activeTools = [:]
    }

    private func handleChatStateEvent(_ event: OpenClawClient.ChatStateEvent) {
        if let thinking = event.thinking, !thinking.isEmpty {
            appendThinkingText(thinking)
        }

        switch event.state {
        case "delta":
            applyChatTextFallback(event.text, runId: event.runId, isFinal: false)
            if hasActiveRuns || runToMessageId[event.runId] != nil || currentStreamingMessageId != nil {
                agentState = .responding
            }

        case "final":
            finalizeThinkingMessage(for: event.runId)
            applyChatTextFallback(event.text, runId: event.runId, isFinal: true)
            appendOpenClawToolSummary(runId: event.runId, terminalState: event.state)
            finalizeStreamingMessage(for: event.runId)
            agentState = .idle
            clearRunState(event.runId)

        case "aborted":
            finalizeThinkingMessage(for: event.runId)
            applyChatTextFallback(event.text, runId: event.runId, isFinal: true)
            appendOpenClawToolSummary(runId: event.runId, terminalState: event.state)
            finalizeStreamingMessage(for: event.runId)
            agentState = .stopped(displayStopReason(event.stopReason))
            clearRunState(event.runId)

        case "error":
            finalizeThinkingMessage(for: event.runId)
            applyChatTextFallback(event.text, runId: event.runId, isFinal: true)
            appendOpenClawToolSummary(runId: event.runId, terminalState: event.state)
            finalizeStreamingMessage(for: event.runId)
            agentState = .error(event.errorMessage ?? "执行失败")
            clearRunState(event.runId)

        default:
            break
        }
    }

    private func appendStreamingText(_ delta: String) {
        if currentThinkingMessageId != nil {
            finalizeThinkingMessage()
        }

        print("🔍 [ChatViewModel \(viewModelId)] appendStreamingText called with delta: '\(delta)'")
        print("🔍 [ChatViewModel \(viewModelId)] Delta length: \(delta.count)")
        print("🔍 [ChatViewModel \(viewModelId)] Current queue size BEFORE append: \(characterQueue.count)")
        print("🔍 [ChatViewModel \(viewModelId)] Current streaming message ID: \(currentStreamingMessageId?.uuidString ?? "nil")")

        guard let messageId = currentStreamingMessageId,
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            print("⚠️ [ChatViewModel \(viewModelId)] No streaming message found")
            return
        }

        print("🔍 [ChatViewModel \(viewModelId)] Current message text length: \(messages[index].text.count)")
        if let runId = runToMessageId.first(where: { $0.value == messageId })?.key {
            runsWithAgentTextStream.insert(runId)
        }

        // 将新到的文字拆分成字符，加入缓冲队列
        characterQueue.append(contentsOf: delta)
        print("🔍 [ChatViewModel \(viewModelId)] Queue size AFTER append: \(characterQueue.count)")

        // 如果定时器还未启动，启动逐字输出定时器
        if typingTimer == nil {
            print("🔍 [ChatViewModel \(viewModelId)] Starting typing animation timer")
            startTypingAnimation()
        }
    }

    private func startTypingAnimation() {
        emptyQueueCount = 0  // 重置计数器
        // ✅ 使用 MainActor.assumeIsolated 代替 Task，避免异步竞态
        typingTimer = Timer.scheduledTimer(withTimeInterval: typingSpeed, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displayNextCharacter()
            }
        }
    }

    private func displayNextCharacter() {
        guard let messageId = currentStreamingMessageId,
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            stopTypingAnimation()
            return
        }

        // 从队列中取出一个字符
        guard !characterQueue.isEmpty else {
            // 队列为空，可能还会有新数据到来
            // 如果连续 30 次为空（约 0.45 秒），暂停定时器节省资源
            emptyQueueCount += 1
            if emptyQueueCount > 30 {
                stopTypingAnimation()
            }
            return
        }

        // 重置空队列计数
        emptyQueueCount = 0

        let character = characterQueue.removeFirst()
        var message = messages[index]
        message.text.append(character)
        messages[index] = message
    }

    private func stopTypingAnimation() {
        typingTimer?.invalidate()
        typingTimer = nil
        emptyQueueCount = 0
    }

    private func finalizeStreamingMessage(for runId: String? = nil) {
        let targetMessageId = runId.flatMap { runToMessageId[$0] } ?? currentStreamingMessageId
        guard let messageId = targetMessageId,
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }

        if messageId == currentStreamingMessageId {
            // 停止定时器
            stopTypingAnimation()

            // 将队列中剩余的所有字符一次性显示（避免用户等待）
            if !characterQueue.isEmpty {
                var message = messages[index]
                message.text.append(contentsOf: characterQueue)
                messages[index] = message
                characterQueue.removeAll()
            }
        }

        // 标记为完成
        var message = messages[index]
        message.isStreaming = false
        messages[index] = message

        // Save to history (AI response is now complete)
        persistChatMessage(message)

        if messageId == currentStreamingMessageId {
            currentStreamingMessageId = nil
        }

        if let runId {
            runToMessageId.removeValue(forKey: runId)
            runsWithAgentTextStream.remove(runId)
            if let runTools = toolsByRunId[runId], !runTools.isEmpty {
                messages[index].toolExecutions = runTools.values.sorted { $0.startTime < $1.startTime }
            }
            toolsByRunId.removeValue(forKey: runId)
            activeTools = [:]
        } else if let boundRunId = runToMessageId.first(where: { $0.value == messageId })?.key {
            runToMessageId.removeValue(forKey: boundRunId)
            toolsByRunId.removeValue(forKey: boundRunId)
            runsWithAgentTextStream.remove(boundRunId)
            activeTools = [:]
        }
    }

    private func handleStreamingError(_ error: String) {
        presentError(
            error,
            log: "聊天流式处理失败：\(error)"
        )
        finalizeThinkingMessage()

        // 停止定时器并清空队列
        stopTypingAnimation()
        characterQueue.removeAll()

        // Remove streaming placeholder
        if let id = currentStreamingMessageId {
            messages.removeAll { $0.id == id }
            currentStreamingMessageId = nil
        }

        runToMessageId.removeAll()
        toolsByRunId.removeAll()
        runsWithAgentTextStream.removeAll()
        activeTools.removeAll()
    }

    private func handleError(_ error: Error) {
        presentError(
            error.localizedDescription,
            log: "聊天流式处理失败：\(error.localizedDescription)"
        )

        // Add error message
        let errorChatMessage = ChatMessage(
            text: "抱歉，发生了错误: \(error.localizedDescription)",
            isUser: false
        )
        messages.append(errorChatMessage)

        // Save to history
        persistChatMessage(errorChatMessage)
    }

    private func handleOtherChannelActivity(channels: Set<String>, isActive: Bool) {
        activeChannels = channels
        otherChannelActive = isActive
    }

    // MARK: - Audio Recording Methods

    // Hold-to-speak recording (doesn't change recordingState)
    func startHoldToSpeakRecording() {
        // Check connection status
        guard isConnected else {
            presentError(
                "未连接到 IronClaw，无法使用语音功能",
                log: "按住说话被阻止：HTTP 主链路未连接"
            )
            return
        }

        // Prevent duplicate start
        guard !isHoldingSpeakButton else {
            print("⚠️ 按住说话已经在进行中")
            return
        }

        // Clear previous state
        realtimeTranscript = ""
        partialTranscript = ""

        isHoldingSpeakButton = true
        print("🎤 [DEBUG] isHoldingSpeakButton = true")

        // Start audio recording (file-based, not streaming)
        do {
            try realtimeAudioManager.startRecording()
            print("🎤 [DEBUG] 录音管理器已启动（文件模式）")
        } catch {
            print("❌ 录音启动失败: \(error)")
            isHoldingSpeakButton = false
            presentError(
                "录音启动失败: \(error.localizedDescription)",
                log: "按住说话录音启动失败：\(error.localizedDescription)"
            )
            return
        }

        recordingStartTime = Date()
        recordingDuration = 0

        print("🎤 [DEBUG] 准备启动定时器，recordingStartTime = \(recordingStartTime!)")

        // Start timer - @MainActor 确保已经在主线程
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            // ✅ 使用 MainActor.assumeIsolated 避免 Sendable 警告
            MainActor.assumeIsolated {
                guard let self = self else {
                    timer.invalidate()
                    return
                }
                // ✅ 首先检查是否还在录音状态
                guard self.isHoldingSpeakButton else {
                    print("⚠️ [TIMER] isHoldingSpeakButton = false, 停止计时器")
                    timer.invalidate()
                    return
                }
                guard let startTime = self.recordingStartTime else {
                    print("⚠️ [TIMER] recordingStartTime is nil!")
                    timer.invalidate()
                    return
                }
                let duration = Date().timeIntervalSince(startTime)
                self.recordingDuration = duration
            }
        }

        print("🎤 [DEBUG] 定时器已创建: \(recordingTimer != nil ? "成功" : "失败")")

        // Haptic feedback
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        print("🎤 开始按住说话录音（文件模式）")
    }

    func cancelHoldToSpeakRecording() {
        print("🎤 [DEBUG] cancelHoldToSpeakRecording 被调用")

        // Stop recording if in progress
        guard isHoldingSpeakButton else {
            print("⚠️ 按住说话未在进行中，无需取消")
            return
        }

        // Reset state
        isHoldingSpeakButton = false
        objectWillChange.send()

        // Stop and clear timer
        recordingTimer?.invalidate()
        recordingTimer = nil

        // Reset recording state
        recordingDuration = 0
        recordingStartTime = nil
        realtimeTranscript = ""
        partialTranscript = ""

        // Stop recording without processing
        _ = realtimeAudioManager.stopRecording()

        print("❌ 已取消按住说话录音")

        // Haptic feedback
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.warning)
    }

    func finishHoldToSpeakRecording() async {
        print("🎤 [DEBUG] finishHoldToSpeakRecording 被调用")
        print("🎤 [DEBUG] isHoldingSpeakButton = \(isHoldingSpeakButton)")
        print("🎤 [DEBUG] isFinishingRecording = \(isFinishingRecording)")

        // ✅ 防止重复调用（例如 onDisappear 和用户松手同时触发）
        guard !isFinishingRecording else {
            print("⚠️ 已经在结束录音流程中，跳过重复调用")
            return
        }

        // Prevent duplicate finish
        guard isHoldingSpeakButton else {
            print("⚠️ 按住说话未在进行中，跳过")
            return
        }

        // ✅ 标记正在结束
        isFinishingRecording = true

        // ✅ 立即重置按钮状态，确保 UI 响应和定时器停止
        isHoldingSpeakButton = false
        objectWillChange.send()  // ✅ 强制触发 UI 更新
        print("🎤 [DEBUG] isHoldingSpeakButton = false (已重置，强制刷新UI)")

        // ✅ 在主线程上强制停止并清除定时器
        if let timer = recordingTimer {
            if timer.isValid {
                timer.invalidate()
                print("🎤 [DEBUG] 定时器已失效")
            }
            recordingTimer = nil
            print("🎤 [DEBUG] 定时器已清除")
        } else {
            print("⚠️ [DEBUG] 定时器为 nil，无需清除")
        }

        // ✅ 重置录音时长和开始时间
        recordingDuration = 0
        recordingStartTime = nil

        // ✅ 立即停止录音
        let audioData = realtimeAudioManager.stopRecording()
        print("🎤 [DEBUG] 录音已停止，音频数据大小: \(audioData.count) bytes")

        // Check if we have audio data
        guard audioData.count > 0 else {
            print("⚠️ [DEBUG] 音频数据为空，跳过识别")
            isFinishingRecording = false
            return
        }

        // ✅ 显示"识别中"状态
        isRecognizingAudio = true
        print("🎤 [DEBUG] 开始识别音频...")

        // ✅ Setup streaming callback to update UI in real-time
        fileASRService.onPartialResult = { [weak self] text, isFinal in
            guard let self = self else { return }
            Task { @MainActor in
                if isFinal {
                    // Final result - append to recognized text
                    self.realtimeTranscript += text
                    self.partialTranscript = ""
                    print("🎤 [Streaming] 最终结果: '\(text)'")
                } else {
                    // Partial result - show as interim
                    self.partialTranscript = text
                    print("🎤 [Streaming] 部分结果: '\(text)'")
                }
            }
        }

        // Save audio to temp file
        guard let wavURL = realtimeAudioManager.saveAsWAVFile(audioData) else {
            print("❌ 保存音频文件失败")
            await MainActor.run {
                self.presentError(
                    "保存音频文件失败",
                    log: "语音识别前保存音频失败"
                )
                self.isRecognizingAudio = false
                self.isFinishingRecording = false
            }
            return
        }

        print("🎤 [DEBUG] 音频已保存为 WAV: \(wavURL.path)")

        // Transcribe using FileASRService
        do {
            let transcript = try await fileASRService.transcribeFile(wavURL)
            print("✅ 文件转写成功: '\(transcript)'")

            // Clean up temp file
            try? FileManager.default.removeItem(at: wavURL)

            // ✅ 清除识别状态和回调
            isRecognizingAudio = false
            fileASRService.onPartialResult = nil

            // Haptic feedback
            let impact = UIImpactFeedbackGenerator(style: .heavy)
            impact.impactOccurred()

            // Send as text message if we have transcript
            if !transcript.isEmpty {
                inputText = transcript
                print("🎤 [DEBUG] 准备发送消息: '\(transcript)'")
                sendMessage()
                print("🎤 [DEBUG] 消息已发送")
            } else {
                print("⚠️ [DEBUG] 转写结果为空，不发送消息")
            }

        } catch {
            print("❌ 文件转写失败: \(error)")

            // Clean up temp file
            try? FileManager.default.removeItem(at: wavURL)

            // ✅ 清除回调
            fileASRService.onPartialResult = nil

            await MainActor.run {
                self.presentError(
                    "语音识别失败: \(error.localizedDescription)",
                    log: "按住说话录音转写失败：\(error.localizedDescription)"
                )
                self.isRecognizingAudio = false
            }
        }

        // ✅ 重置标志，允许下次录音
        isFinishingRecording = false
        print("🎤 [DEBUG] isFinishingRecording = false (已重置)")
    }



    // MARK: - Toolbar Actions

    func handleFileSelected(_ url: URL) {
        // Get file info
        let fileName = url.lastPathComponent
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let fileSizeText = formatFileSize(fileSize)

        // Create file message
        let fileMessage = ChatMessage(
            text: "📎 \(fileName) (\(fileSizeText))",
            isUser: true
        )

        messages.append(fileMessage)

        persistChatMessage(fileMessage)

        // TODO: Upload file to OneDrive and sync to Context Brain
        print("📎 文件选择: \(fileName), 大小: \(fileSizeText)")

        // Temporary response
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let aiResponse = ChatMessage(
                text: "我收到了你的文件「\(fileName)」！（文件上传功能开发中...）",
                isUser: false
            )
            messages.append(aiResponse)

            persistChatMessage(aiResponse)
        }
    }

    func handleImageSelected(_ image: UIImage) {
        // Save image temporarily
        let imageSizeText = formatImageSize(image)

        // Create image message
        let imageMessage = ChatMessage(
            text: "🖼️ 图片 (\(imageSizeText))",
            isUser: true
        )

        messages.append(imageMessage)

        persistChatMessage(imageMessage)

        // TODO: Upload image and process with vision model
        print("🖼️ 图片选择: \(imageSizeText)")

        // Temporary response
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let aiResponse = ChatMessage(
                text: "我收到了你的图片！（图片处理功能开发中...）",
                isUser: false
            )
            messages.append(aiResponse)

            persistChatMessage(aiResponse)
        }
    }

    func handleQuickRecord() {
        // Show meeting recording card (wait for user to click start)
        showMeetingRecordingCard()
        print("🎤 显示录音纪要卡片")
    }

    func handleMoreOptions() {
        // ✅ 显示更多选项菜单
        showMoreOptions = true
        print("⋯ 显示更多选项菜单")
    }

    // MARK: - Helper Methods

    private func formatFileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    private func formatImageSize(_ image: UIImage) -> String {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        return "\(width)×\(height)"
    }

    // MARK: - Meeting Recording (录音纪要)

    /// 显示录音纪要卡片（等待用户点击开始）
    func showMeetingRecordingCard() {
        isMeetingRecording = true
        meetingPhase = .ready
        print("📝 显示录音纪要卡片")
    }

    /// 返回键盘输入模式（仅在未开始录音时可用）
    func dismissMeetingRecording() {
        guard meetingPhase == .ready else { return }
        isMeetingRecording = false
        meetingPhase = .ready
        print("⬅️ 返回键盘输入模式")
    }

    /// 开始录音纪要
    func startMeetingRecording() {
        // Check connection status
        guard isConnected else {
            presentError(
                "未连接到 IronClaw，无法使用录音功能",
                log: "会议录音启动被阻止：HTTP 主链路未连接"
            )
            return
        }

        meetingPhase = .recording
        recordingDuration = 0
        recordingStartTime = Date()

        do {
            try meetingRecordingManager.startRecording()
            print("📝 开始会议录音")

            // Start timer
            recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self = self else { return }
                    if self.meetingPhase == .recording {
                        self.recordingDuration = Date().timeIntervalSince(self.recordingStartTime ?? Date())
                    }
                }
            }

            // Haptic feedback
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
        } catch {
            isMeetingRecording = false
            meetingPhase = .ready
            presentError(
                "启动录音失败: \(error.localizedDescription)",
                log: "会议录音启动失败：\(error.localizedDescription)"
            )
            print("❌ 启动会议录音失败: \(error)")
        }
    }

    func pauseMeetingRecording() {
        meetingRecordingManager.pauseRecording()
        meetingPhase = .paused
        print("⏸️ 暂停会议录音")
    }

    func resumeMeetingRecording() {
        meetingRecordingManager.resumeRecording()
        meetingPhase = .recording
        recordingStartTime = Date().addingTimeInterval(-recordingDuration)  // Adjust start time
        print("▶️ 继续会议录音")
    }

    func cancelMeetingRecording() {
        meetingRecordingManager.stopRecording()
        recordingTimer?.invalidate()

        isMeetingRecording = false
        meetingPhase = .ready
        recordingDuration = 0
        recordingStartTime = nil

        print("❌ 取消会议录音")

        // Haptic feedback
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.warning)
    }

    func finishMeetingRecording() async {
        recordingTimer?.invalidate()

        // Stop recording
        let audioData = meetingRecordingManager.stopRecording()
        isMeetingRecording = false
        meetingPhase = .ready

        let duration = recordingDuration
        recordingDuration = 0
        recordingStartTime = nil

        print("📝 会议录音结束，音频大小: \(audioData.count) bytes, 时长: \(String(format: "%.1f", duration))s")

        // Check if we have audio data
        guard audioData.count > 0 else {
            print("⚠️ 音频数据为空")
            return
        }

        // Show recognizing state
        isRecognizingAudio = true

        // Save audio to temp file
        guard let wavURL = meetingRecordingManager.saveAsWAVFile(audioData) else {
            print("❌ 保存音频文件失败")
            await MainActor.run {
                self.presentError(
                    "保存音频文件失败",
                    log: "会议录音转写前保存音频文件失败"
                )
                self.isRecognizingAudio = false
            }
            return
        }

        print("📝 音频已保存为 WAV: \(wavURL.path)")

        // Transcribe using FileASRService
        do {
            let transcript = try await fileASRService.transcribeFile(wavURL)
            print("✅ 会议录音转写成功: '\(transcript)'")

            // Clean up temp file
            try? FileManager.default.removeItem(at: wavURL)

            // Clear recognizing state
            isRecognizingAudio = false

            // Haptic feedback
            let impact = UIImpactFeedbackGenerator(style: .heavy)
            impact.impactOccurred()

            // Send as text message if we have transcript
            if !transcript.isEmpty {
                inputText = transcript
                print("📝 准备发送会议纪要: '\(transcript)'")
                sendMessage()
            } else {
                print("⚠️ 转写结果为空")
            }

        } catch {
            print("❌ 会议录音转写失败: \(error)")

            // Clean up temp file
            try? FileManager.default.removeItem(at: wavURL)

            await MainActor.run {
                self.presentError(
                    "语音识别失败: \(error.localizedDescription)",
                    log: "会议录音转写失败：\(error.localizedDescription)"
                )
                self.isRecognizingAudio = false
            }
        }
    }

    // MARK: - Tool Execution Handlers (NEW)

    private func handleToolStart(runId: String, toolId: String, toolName: String, input: String?) {
        bindCurrentStreamingMessage(to: runId)
        let tool = ToolExecution(
            id: toolId,
            runId: runId,
            name: toolName,
            phase: .start,
            input: input,
            output: nil,
            error: nil,
            startTime: Date(),
            endTime: nil
        )
        var runTools = toolsByRunId[runId] ?? [:]
        runTools[toolId] = tool
        toolsByRunId[runId] = runTools
        activeTools = runTools
        agentState = .responding  // Agent is actively working

        // Update the current streaming message with tool executions
        updateStreamingMessageWithTools(runId: runId)
    }

    private func handleToolUpdate(runId: String, toolId: String, partialOutput: String) {
        guard var runTools = toolsByRunId[runId],
              var tool = runTools[toolId] else {
            print("⚠️ [ChatViewModel] Tool update for unknown toolId: \(toolId), runId: \(runId)")
            return
        }

        tool.phase = .update
        tool.output = partialOutput
        runTools[toolId] = tool
        toolsByRunId[runId] = runTools
        activeTools = runTools

        // Update the current streaming message with tool executions
        updateStreamingMessageWithTools(runId: runId)
    }

    private func handleToolResult(runId: String, toolId: String, output: String?, error: String?) {
        guard var runTools = toolsByRunId[runId],
              var tool = runTools[toolId] else {
            print("⚠️ [ChatViewModel] Tool result for unknown toolId: \(toolId), runId: \(runId)")
            return
        }

        tool.phase = .result
        tool.output = output
        tool.error = error
        tool.endTime = Date()
        runTools[toolId] = tool
        toolsByRunId[runId] = runTools
        activeTools = runTools

        // Update the current streaming message with tool executions
        updateStreamingMessageWithTools(runId: runId)
    }

    private func updateStreamingMessageWithTools(runId: String) {
        guard let messageId = runToMessageId[runId] ?? currentStreamingMessageId,
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }

        // Convert run-specific dict to ordered array
        let toolExecutions = (toolsByRunId[runId] ?? [:]).values
            .sorted { lhs, rhs in lhs.startTime < rhs.startTime }
        messages[index].toolExecutions = toolExecutions.isEmpty ? nil : toolExecutions
    }

    private func appendOpenClawToolSummary(runId: String, terminalState: String) {
        guard let summary = openClawToolSummaryText(runId: runId, terminalState: terminalState),
              let messageId = runToMessageId[runId] ?? currentStreamingMessageId,
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }

        let existing = messages[index].text
        if existing.contains(summary) {
            return
        }

        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages[index].text = summary
        } else {
            messages[index].text = "\(existing)\n\n\(summary)"
        }
    }

    private func openClawToolSummaryText(runId: String, terminalState: String) -> String? {
        guard let runTools = toolsByRunId[runId], !runTools.isEmpty else {
            return nil
        }

        let tools = runTools.values
        let callCount = tools.count
        let failedCount = tools.filter { $0.status == .failed }.count
        let succeededCount = tools.filter { $0.status == .completed }.count
        let uniqueToolCount = Set(tools.map { $0.name }).count

        let startedAt = tools.map(\.startTime).min() ?? Date()
        let completedAt = tools.compactMap { $0.endTime ?? $0.startTime }.max() ?? startedAt
        let duration = max(completedAt.timeIntervalSince(startedAt), 0)
        let durationText: String = duration >= 10
            ? String(format: "%.0fs", duration)
            : String(format: "%.1fs", duration)

        let terminal = terminalState.lowercased()
        let statusLabel: String
        if terminal == "aborted" {
            statusLabel = "已中止"
        } else if terminal == "error" {
            statusLabel = "失败"
        } else {
            statusLabel = "已完成"
        }

        return "工具摘要（\(statusLabel)）：调用 \(callCount) 次，成功 \(succeededCount)，失败 \(failedCount)，不同工具 \(uniqueToolCount)，耗时 \(durationText)。"
    }

    // MARK: - Cleanup

    func cleanup() {
        print("🧹 [ChatViewModel \(viewModelId)] Cleaning up callbacks")
        // Clear typing animation
        stopTypingAnimation()
        characterQueue.removeAll()

        // Clear callbacks to prevent stale instances from processing streams
        chatPlugin.unbind(client: clawdBotClient)

        runToMessageId.removeAll()
        toolsByRunId.removeAll()
        runsWithAgentTextStream.removeAll()
        activeTools.removeAll()
    }

    private func applyChatTextFallback(_ text: String?, runId: String, isFinal: Bool) {
        guard !runsWithAgentTextStream.contains(runId) else { return }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let messageId = runToMessageId[runId] ?? currentStreamingMessageId,
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }

        let current = messages[index].text
        if current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isFinal || text.count >= current.count {
            messages[index].text = text
        }
    }

    private func mapStopReasonCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        switch normalized {
        case "stop", "rpc", "abort", "aborted", "user", "cancel", "cancelled", "canceled":
            return "用户已停止"
        case "timeout":
            return "执行超时"
        case "tool_calls":
            return "等待工具执行"
        case "length", "max_output_tokens":
            return "达到输出长度限制"
        default:
            return nil
        }
    }

    private func displayStopReason(_ raw: String?) -> String? {
        if let mapped = mapStopReasonCode(raw) {
            return mapped
        }
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Message Sync (NEW)

    /// Sync messages from IronClaw using session history API
    func syncMessagesFromIronClaw() async {
        // Prevent concurrent sync
        guard !isSyncing else {
            print("⚠️ [ChatViewModel] Sync already in progress, skipping")
            return
        }

        // Wait for connection if not connected
        if !clawdBotClient.isConnected {
            print("⚠️ [ChatViewModel] Not connected, waiting for connection...")
            // Wait up to 5 seconds for connection
            for _ in 0..<50 {
                if clawdBotClient.isConnected {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }

            guard clawdBotClient.isConnected else {
                print("❌ [ChatViewModel] Failed to connect after 5 seconds")
                isSyncing = false
                return
            }
        }

        isSyncing = true
        print("🔄 [ChatViewModel] Starting message sync from IronClaw...")

        do {
            // Fetch history from IronClaw
            let response = try await clawdBotClient.fetchChatHistory(
                sessionKey: sessionKey,
                limit: 200
            )

            guard let payload = response.historyPayload else {
                print("⚠️ [ChatViewModel] No payload in history response")
                isSyncing = false
                return
            }

            let resolvedThinkingLevel = payload.thinkingLevel ?? "off"
            if currentThinkingLevel != resolvedThinkingLevel {
                currentThinkingLevel = resolvedThinkingLevel
            }

            print("📬 [ChatViewModel] Received \(payload.messages.count) messages from IronClaw")

            await MainActor.run {
                let ironClawMessages = payload.messages
                    .map(convertHistoryMessage)
                    .sorted { $0.timestamp < $1.timestamp }

                if !ironClawMessages.isEmpty {
                    messages = ironClawMessages
                    processedMessageIds = Set(ironClawMessages.map { $0.id.uuidString })
                    Task { [weak self] in
                        await self?.persistIronClawSnapshot(ironClawMessages)
                    }
                }

                if let lastMsg = payload.messages.last {
                    lastSyncTimestamp = TimeInterval(lastMsg.timestamp) / 1000.0
                }

                if messages.isEmpty {
                    let welcomeText = agent != nil
                        ? "你好！我是 \(agent!.displayName)。\(agent!.description ?? "")有什么可以帮你的吗？"
                        : "你好！我是你的 AI 助手。有什么可以帮你的吗？"

                    let welcomeMessage = ChatMessage(
                        text: welcomeText,
                        isUser: false
                    )
                    messages.append(welcomeMessage)

                    persistChatMessage(welcomeMessage)
                }

                print("✅ [ChatViewModel] Sync complete - total messages: \(messages.count)")
            }

        } catch {
            print("❌ [ChatViewModel] Sync failed: \(error)")
        }

        isSyncing = false
    }

    func updateCurrentThinkingLevel(_ level: String) {
        let trimmedLevel = level.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLevel.isEmpty else { return }
        currentThinkingLevel = trimmedLevel
    }

    /// Convert IronClaw history message to ChatMessage
    private func convertHistoryMessage(_ historyMsg: ChatHistoryResponse.HistoryMessage) -> ChatMessage {
        let thinkingText = historyMsg.content
            .filter { $0.type == "thinking" }
            .compactMap { $0.text }
            .joined(separator: "\n")

        let regularText = historyMsg.content
            .filter { $0.type != "thinking" }
            .compactMap { $0.text }
            .joined(separator: "\n")

        let text: String
        if !thinkingText.isEmpty && !regularText.isEmpty {
            text = "<thinking>\n\(thinkingText)\n</thinking>\n\n\(regularText)"
        } else if !thinkingText.isEmpty {
            text = "<thinking>\n\(thinkingText)\n</thinking>"
        } else {
            text = regularText
        }

        // Convert toolUse to ToolExecution if present
        var toolExecutions: [ToolExecution]? = nil
        if let toolUses = historyMsg.toolUse, !toolUses.isEmpty {
            toolExecutions = toolUses.map { toolUse in
                ToolExecution(
                    id: toolUse.id,
                    runId: nil,
                    name: toolUse.name,
                    phase: .result,
                    input: jsonToString(toolUse.input),
                    output: findToolResult(toolUseId: toolUse.id, results: historyMsg.toolResult),
                    error: nil,
                    startTime: Date(timeIntervalSince1970: TimeInterval(historyMsg.timestamp) / 1000.0),
                    endTime: Date(timeIntervalSince1970: TimeInterval(historyMsg.timestamp) / 1000.0)
                )
            }
        }

        return ChatMessage(
            id: stableUUID(for: historyMsg.id),
            text: text,
            isUser: historyMsg.role == "user",
            timestamp: Date(timeIntervalSince1970: TimeInterval(historyMsg.timestamp) / 1000.0),
            isStreaming: false,
            toolExecutions: toolExecutions
        )
    }

    private func stableUUID(for sourceId: String) -> UUID {
        if let uuid = UUID(uuidString: sourceId) {
            return uuid
        }

        var bytes = [UInt8](repeating: 0, count: 16)
        let utf8Bytes = Array(sourceId.utf8)
        for (index, byte) in utf8Bytes.enumerated() {
            bytes[index % 16] = bytes[index % 16] ^ (byte &+ UInt8((index * 31) % 255))
        }

        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let uuidString = "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20).prefix(12))"
        return UUID(uuidString: uuidString) ?? UUID()
    }

    private func jsonToString(_ input: AnyCodable?) -> String? {
        guard let input = input else { return nil }
        if let dict = input.value as? [String: Any] {
            if let jsonData = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                return jsonString
            }
        }
        return "\(input.value)"
    }

    private func findToolResult(toolUseId: String, results: [ChatHistoryResponse.HistoryMessage.ToolResult]?) -> String? {
        guard let results = results else { return nil }
        return results.first(where: { $0.tool_use_id == toolUseId })?.content
    }

    private func appendThinkingText(_ thinking: String) {
        guard !thinking.isEmpty else { return }

        if let messageId = currentThinkingMessageId,
           let index = messages.firstIndex(where: { $0.id == messageId }) {
            var message = messages[index]
            if !message.text.hasSuffix("\n") {
                message.text.append("\n")
            }
            message.text.append(thinking)
            messages[index] = message
            return
        }

        let thinkingMessage = ChatMessage(
            text: "<thinking>\n\(thinking)",
            isUser: false,
            isStreaming: true
        )
        currentThinkingMessageId = thinkingMessage.id
        messages.append(thinkingMessage)
    }

    private func finalizeThinkingMessage(for _: String? = nil) {
        guard let messageId = currentThinkingMessageId,
              let index = messages.firstIndex(where: { $0.id == messageId }) else {
            return
        }

        var message = messages[index]
        if !message.text.contains("</thinking>") {
            if !message.text.hasSuffix("\n") {
                message.text.append("\n")
            }
            message.text.append("</thinking>")
        }
        message.isStreaming = false
        messages[index] = message

        persistChatMessage(message)
        currentThinkingMessageId = nil
    }

    // MARK: - Abort Chat

    /// Abort the current ongoing chat generation
    func abortChat() async {
        do {
            let abortedCount = try await clawdBotClient.abortChat(sessionKey: sessionKey, runId: nil)
            print("[ChatViewModel] ✅ Aborted \(abortedCount) ongoing chat(s)")

            // Stop typing animation and clear queue
            await MainActor.run {
                stopTypingAnimation()
                characterQueue.removeAll()

                // Reset agent state
                agentState = .idle
                isSending = false

                // Finalize current streaming message if any
                if currentStreamingMessageId != nil {
                    finalizeStreamingMessage()
                }
            }
        } catch {
            print("[ChatViewModel] ❌ Failed to abort chat: \(error)")
            await MainActor.run {
                presentError(
                    "终止对话失败: \(error.localizedDescription)",
                    log: "终止对话失败：\(error.localizedDescription)"
                )
            }
        }
    }

    /// Stop the oldest run in the queue (按 FIFO 顺序)
    func stopOldestRun() async {
        do {
            let abortedCount = try await clawdBotClient.abortOldestRun()
            print("[ChatViewModel] ✅ Aborted oldest run, count: \(abortedCount)")
        } catch {
            // 只打印日志，不弹窗提示用户
            // 因为响应可能已经结束，这是正常情况
            print("[ChatViewModel] ❌ Failed to abort oldest run: \(error)")
        }
    }

}
