//
//  CLISessionViewModel.swift
//  contextgo
//
//  ViewModel for native CLI relay session chat interface.
//

import Foundation
import Combine
import UserNotifications

@MainActor
class CLISessionViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var messages: [CLIMessage] = []
    @Published var inputText: String = ""
    @Published var isSending: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var isThinking: Bool = false
    @Published var isSyncingRemoteMessages: Bool = false
    @Published var isLoadingOlderLocalMessages: Bool = false
    @Published var canLoadOlderLocalMessages: Bool = false
    @Published var activityState: RelayClient.ActivityState = .idle
    @Published var runtimeStateTitle: String?
    @Published var isAborting: Bool = false
    @Published var permissionActionInFlight: Set<String> = []
    @Published var activeTodoSnapshot: TodoRuntimeSnapshot?

    // Voice input
    @Published var inputMode: InputMode = .text
    @Published var isHoldingSpeakButton: Bool = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var isRecognizing: Bool = false

    // MARK: - Dependencies
    private let session: CLISession
    private let client: RelayClient
    private let coreClient = CoreAPIClient.shared
    private let sessionRepository = LocalSessionRepository.shared
    private let voiceManager = VoiceInputManager()
    private let messageParsingQueue = DispatchQueue(label: "contextgo.cli.message-parsing", qos: .userInitiated)
    private var cancellables = Set<AnyCancellable>()
    private var knownToolNames: [String: String] = [:]
    private let permissionPlaceholderPrefix = "perm-state:"
    private var notifiedPendingPermissionKeys: Set<String> = []

    private var lastSyncedSeq: Int = 0
    private let localMessagePageSize = 60
    private var localLoadedTailCount: Int = 0
    private var hasSyncedAgentStateFromRemote: Bool = false
    private var remoteSessionMissing: Bool = false
    private var authoritativeActivityState: RelayClient.ActivityState?
    private var authoritativeAgentStateVersion: Int = -1
    private var ephemeralActivityState: RelayClient.ActivityState = .idle
    private var localTurnPending: Bool = false
    private var pendingPersistSnapshotsById: [String: CLIMessage] = [:]
    private var persistFlushTask: Task<Void, Never>?
    private let persistDebounceNanoseconds: UInt64 = 250_000_000

    private struct ParsedPayloadBatch {
        let messages: [CLIMessage]
        let knownToolNames: [String: String]
    }

    struct TodoRuntimeItem: Identifiable, Equatable {
        let id: String
        let content: String
        let status: String
        let priority: String?
    }

    struct TodoRuntimeSnapshot: Equatable {
        let items: [TodoRuntimeItem]
        let completedCount: Int
        let totalCount: Int
        let updatedAt: Date

        var remainingCount: Int {
            max(totalCount - completedCount, 0)
        }
    }

    var hasActiveRun: Bool {
        if isSending || isAborting || localTurnPending {
            return true
        }

        switch resolvedSessionActivityState() {
        case .waitingForPermission:
            return true
        case .thinking:
            return true
        case .idle:
            return false
        }
    }

    private var hasPendingPermissionRequests: Bool {
        return messages.contains { message in
            return (message.toolUse ?? []).contains { tool in
                tool.permission?.status == .pending
            }
        }
    }

    private var hasRunningToolWork: Bool {
        return messages.contains { message in
            return (message.toolUse ?? []).contains { tool in
                tool.status == .running || tool.status == .pending
            }
        }
    }

    private func resolvedSessionActivityState() -> RelayClient.ActivityState {
        if hasPendingPermissionRequests {
            return .waitingForPermission
        }

        if let authoritativeActivityState {
            switch authoritativeActivityState {
            case .waitingForPermission:
                return .waitingForPermission
            case .thinking:
                return .thinking
            case .idle:
                if ephemeralActivityState == .waitingForPermission {
                    return .waitingForPermission
                }
                if ephemeralActivityState == .thinking {
                    return .thinking
                }
                return .idle
            }
        }

        if ephemeralActivityState == .waitingForPermission {
            return .waitingForPermission
        }
        if ephemeralActivityState == .thinking {
            return .thinking
        }
        if hasRunningToolWork {
            return .thinking
        }
        return .idle
    }

    private func syncActivityPresentationFromState() {
        let resolved = resolvedSessionActivityState()
        activityState = resolved
        isThinking = (resolved == .thinking)
    }

    private func applyEphemeralActivityState(_ state: RelayClient.ActivityState) {
        ephemeralActivityState = state
        syncActivityPresentationFromState()
        if resolvedSessionActivityState() == .idle {
            settleRunningToolsOnIdleIfNeeded()
        }
        refreshRuntimeStateTitle()
    }

    private func applyAuthoritativeActivityState(
        _ state: RelayClient.ActivityState,
        version: Int?
    ) {
        if let version {
            guard version >= authoritativeAgentStateVersion else { return }
            authoritativeAgentStateVersion = version
        } else if authoritativeAgentStateVersion >= 0 {
            // Ignore unversioned updates after we have a versioned source-of-truth.
            return
        }

        authoritativeActivityState = state
        switch state {
        case .thinking, .waitingForPermission:
            localTurnPending = true
        case .idle:
            localTurnPending = false
        }
        syncActivityPresentationFromState()
        if resolvedSessionActivityState() == .idle {
            settleRunningToolsOnIdleIfNeeded()
        }
        refreshRuntimeStateTitle()
    }

    private var pendingPermissionIDs: [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for message in messages {
            guard let tools = message.toolUse else { continue }
            for tool in tools {
                guard let permission = tool.permission, permission.status == .pending else { continue }
                let trimmed = permission.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                if seen.insert(trimmed).inserted {
                    ordered.append(trimmed)
                }
            }
        }

        return ordered
    }

    private func normalizePermissionIDForMatch(_ id: String) -> String {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if let regex = try? NSRegularExpression(pattern: #"#r\d+$"#, options: [.caseInsensitive]) {
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            return regex.stringByReplacingMatches(in: trimmed, options: [], range: range, withTemplate: "")
        }
        return trimmed
    }

    private func resolvePermissionActionTargetID(_ permissionId: String) -> String {
        let requested = permissionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingIDs = pendingPermissionIDs
        guard !pendingIDs.isEmpty else { return requested }

        if !requested.isEmpty && pendingIDs.contains(requested) {
            return requested
        }

        let normalizedRequested = normalizePermissionIDForMatch(requested)
        if !normalizedRequested.isEmpty,
           let matched = pendingIDs.first(where: { normalizePermissionIDForMatch($0) == normalizedRequested }) {
            return matched
        }

        if pendingIDs.count == 1, let onlyID = pendingIDs.first {
            return onlyID
        }

        return requested
    }

    private func resolveCompletedPermissionTargetID(preferredId: String, toolName: String) -> String {
        let trimmedPreferred = preferredId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPreferred.isEmpty else { return preferredId }

        if messages.contains(where: { message in
            message.toolUse?.contains(where: { $0.id == trimmedPreferred }) == true
        }) {
            return trimmedPreferred
        }

        let normalizedPreferred = normalizePermissionIDForMatch(trimmedPreferred)
        if !normalizedPreferred.isEmpty {
            for message in messages {
                guard let tools = message.toolUse else { continue }
                for tool in tools {
                    let direct = normalizePermissionIDForMatch(tool.id)
                    let nested = normalizePermissionIDForMatch(tool.permission?.id ?? "")
                    if direct == normalizedPreferred || nested == normalizedPreferred {
                        return tool.id
                    }
                }
            }
        }

        let normalizedToolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var pendingCandidates: [String] = []
        for message in messages {
            guard let tools = message.toolUse else { continue }
            for tool in tools {
                guard let permission = tool.permission, permission.status == .pending else { continue }
                if !normalizedToolName.isEmpty {
                    let candidateToolName = tool.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if candidateToolName != normalizedToolName && candidateToolName != "tool" {
                        continue
                    }
                }
                pendingCandidates.append(tool.id)
            }
        }

        if pendingCandidates.count == 1, let candidate = pendingCandidates.first {
            return candidate
        }

        return trimmedPreferred
    }

    private func resolveLocalPendingPermissionTargetID(_ permissionId: String) -> String? {
        let trimmed = permissionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let pendingIDs = pendingPermissionIDs
        guard !pendingIDs.isEmpty else { return nil }

        if !trimmed.isEmpty, pendingIDs.contains(trimmed) {
            return trimmed
        }

        let normalized = normalizePermissionIDForMatch(trimmed)
        if !normalized.isEmpty,
           let matched = pendingIDs.first(where: { normalizePermissionIDForMatch($0) == normalized }) {
            return matched
        }

        if pendingIDs.count == 1 {
            return pendingIDs.first
        }

        return nil
    }

    private func applyLocalPermissionDecision(
        permissionId: String,
        status: CLIMessage.ToolUse.Permission.PermissionStatus,
        decision: String
    ) {
        guard let localPermissionId = resolveLocalPendingPermissionTargetID(permissionId) else {
            return
        }

        let permission = CLIMessage.ToolUse.Permission(
            id: localPermissionId,
            status: status,
            reason: nil,
            mode: nil,
            allowedTools: nil,
            decision: decision,
            date: Date().timeIntervalSince1970
        )

        let toolStatus: CLIMessage.ToolUse.Status = (status == .approved) ? .success : .error
        upsertPermissionTool(
            permissionId: localPermissionId,
            toolName: "permission",
            input: nil,
            permission: permission,
            status: toolStatus,
            timestamp: Date()
        )
    }

    // MARK: - Initialization

    init(session: CLISession, client: RelayClient, bootstrap: Bool = true) {
        self.session = session
        self.client = client
        setupCallbacks()
        setupVoiceInput()

        if bootstrap {
            Task {
                await ensureLocalSessionExists()
                await loadMessagesFromLocal()
                applyAgentStatePermissions(session.agentState, version: session.agentStateVersion)
            }
        }
    }

    // MARK: - Realtime callbacks

    private func setupCallbacks() {
        client.newMessageSubject
            .filter { [weak self] sessionId, _ in
                guard let self else { return false }
                return sessionId == self.session.id
            }
            .map { $0.messageData }
            .collect(.byTimeOrCount(DispatchQueue.main, .milliseconds(80), 24))
            .sink { [weak self] batchedPayloads in
                guard let self else { return }
                guard !batchedPayloads.isEmpty else { return }

                Task {
                    let parsed = await self.parseIncomingPayloadsInBackground(batchedPayloads)
                    self.mergeKnownToolNames(parsed.knownToolNames)
                    self.applyIncomingMessages(parsed.messages)
                }
            }
            .store(in: &cancellables)

        client.onSessionActivity = { [weak self] sessionId, state in
            guard let self = self, sessionId == self.session.id else { return }
            self.applyEphemeralActivityState(state)
        }
    }

    // MARK: - Message parsing

    nonisolated private static func parseMessageDataRaw(
        _ data: [String: Any],
        knownToolNames: inout [String: String],
        codexOptimizationsEnabled: Bool = false
    ) -> CLIMessage? {
        guard let id = data["id"] as? String,
              let roleString = data["role"] as? String else {
            return nil
        }
        let rawMessageId = data["rawMessageId"] as? String ?? id

        let role: CLIMessage.Role = roleString == "user" ? .user : .assistant
        let selectedSkillContext = extractSelectedSkillContext(from: data)

        var contentBlocks: [CLIMessage.ContentBlock] = []
        var toolMap: [String: CLIMessage.ToolUse] = [:]
        let messageRunId = normalizedNonEmptyString(data["runId"])
        let messageParentRunId = normalizedNonEmptyString(data["parentRunId"])

        if let contentArray = data["content"] as? [[String: Any]] {
            for contentData in contentArray {
                let rawType = (contentData["type"] as? String ?? "text").lowercased()
                let uuid = contentData["uuid"] as? String
                let parentUUID = contentData["parentUUID"] as? String

                switch rawType {
                case "text":
                    if let text = contentData["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if isPlaceholderToolToken(text) {
                            continue
                        }
                        let blockType: CLIMessage.ContentBlock.ContentType =
                            isLikelyPlanningScratchText(text) ? .thinking : .text
                        contentBlocks.append(
                            CLIMessage.ContentBlock(
                                type: blockType,
                                text: text,
                                toolUseId: nil,
                                toolName: nil,
                                toolInput: nil,
                                uuid: uuid,
                                parentUUID: parentUUID
                            )
                        )
                    }

                case "thinking":
                    if let text = contentData["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        contentBlocks.append(
                            CLIMessage.ContentBlock(
                                type: .thinking,
                                text: text,
                                toolUseId: nil,
                                toolName: nil,
                                toolInput: nil,
                                uuid: uuid,
                                parentUUID: parentUUID
                            )
                        )
                    }

                case "agent_reasoning", "agent.reasoning", "agent_reasoning_delta", "agent.reasoning.delta":
                    guard codexOptimizationsEnabled else { continue }
                    if let text = ((contentData["text"] as? String) ?? (contentData["delta"] as? String)),
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        contentBlocks.append(
                            CLIMessage.ContentBlock(
                                type: .thinking,
                                text: text,
                                toolUseId: nil,
                                toolName: nil,
                                toolInput: nil,
                                uuid: uuid,
                                parentUUID: parentUUID
                            )
                        )
                    }

                case "agent_message", "agent.message",
                     "agent_message_delta", "agent.message.delta",
                     "agent_message_content_delta", "agent.message.content.delta":
                    guard codexOptimizationsEnabled else { continue }
                    if let text = ((contentData["text"] as? String) ?? (contentData["delta"] as? String)),
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        contentBlocks.append(
                            CLIMessage.ContentBlock(
                                type: .text,
                                text: text,
                                toolUseId: nil,
                                toolName: nil,
                                toolInput: nil,
                                uuid: uuid,
                                parentUUID: parentUUID
                            )
                        )
                    }

                case "agent_reasoning_section_break", "agent.reasoning.section.break",
                     "item_started", "item-started", "item.started",
                     "item_completed", "item-completed", "item.completed":
                    guard codexOptimizationsEnabled else { break }
                    continue

                case "event":
                    if isSilentProtocolEvent(
                        rawType: rawType,
                        contentData: contentData,
                        codexOptimizationsEnabled: codexOptimizationsEnabled
                    ) {
                        continue
                    }

                    if let text = contentData["text"] as? String,
                       !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        if isSilentProtocolEventText(
                            text,
                            codexOptimizationsEnabled: codexOptimizationsEnabled
                        ) {
                            continue
                        }
                        contentBlocks.append(
                            CLIMessage.ContentBlock(
                                type: .event,
                                text: text,
                                toolUseId: nil,
                                toolName: nil,
                                toolInput: nil,
                                uuid: uuid,
                                parentUUID: parentUUID
                            )
                        )
                    }

                case "task_started", "task-started":
                    guard let taskId = resolveBackgroundTaskIdentifier(
                        contentData: contentData,
                        messageRunId: messageRunId,
                        messageParentRunId: messageParentRunId,
                        blockUUID: uuid,
                        payloadCandidates: [
                            stringifyValue(contentData["payload"] ?? contentData["input"])
                        ],
                        allowEventIDFallback: true
                    ) else {
                        continue
                    }
                    let taskInput = stringifyValue(contentData["payload"] ?? contentData["input"] ?? [
                        "taskId": taskId,
                        "state": "started"
                    ]) ?? "{\"taskId\":\"\(taskId)\",\"state\":\"started\"}"

                    toolMap[taskId] = CLIMessage.ToolUse(
                        id: taskId,
                        name: "BackgroundTask",
                        input: taskInput,
                        output: nil,
                        status: .running,
                        executionTime: nil,
                        description: "后台任务已启动",
                        permission: nil
                    )
                    knownToolNames[taskId] = "BackgroundTask"

                    contentBlocks.append(
                        CLIMessage.ContentBlock(
                            type: .toolUse,
                            text: nil,
                            toolUseId: taskId,
                            toolName: "BackgroundTask",
                            toolInput: ["_raw": taskInput],
                            uuid: uuid,
                            parentUUID: parentUUID
                        )
                    )

                case "task_complete", "task-complete", "task_completed", "task-finished":
                    guard let taskId = resolveBackgroundTaskIdentifier(
                        contentData: contentData,
                        messageRunId: messageRunId,
                        messageParentRunId: messageParentRunId,
                        blockUUID: uuid,
                        payloadCandidates: [
                            stringifyValue(contentData["payload"] ?? contentData["input"])
                        ],
                        allowEventIDFallback: true
                    ) else {
                        continue
                    }
                    let output = (
                        stringifyValue(
                            contentData["message"]
                                ?? contentData["text"]
                                ?? contentData["output"]
                                ?? contentData["result"]
                        ) ?? "后台任务已完成"
                    ).trimmingCharacters(in: .whitespacesAndNewlines)

                    var existing = toolMap[taskId] ?? CLIMessage.ToolUse(
                        id: taskId,
                        name: knownToolNames[taskId] ?? "BackgroundTask",
                        input: nil,
                        output: nil,
                        status: .pending,
                        executionTime: nil,
                        description: nil,
                        permission: nil
                    )
                    if !output.isEmpty {
                        existing.output = output
                    }
                    existing.status = .success
                    toolMap[taskId] = existing
                    knownToolNames[taskId] = existing.name

                    if !output.isEmpty {
                        contentBlocks.append(
                            CLIMessage.ContentBlock(
                                type: .toolResult,
                                text: output,
                                toolUseId: taskId,
                                toolName: existing.name,
                                toolInput: nil,
                                uuid: uuid,
                                parentUUID: parentUUID
                            )
                        )
                    }

                case "turn_aborted", "turn-aborted", "task-failed":
                    guard let taskId = resolveBackgroundTaskIdentifier(
                        contentData: contentData,
                        messageRunId: messageRunId,
                        messageParentRunId: messageParentRunId,
                        blockUUID: uuid,
                        payloadCandidates: [
                            stringifyValue(contentData["payload"] ?? contentData["input"])
                        ],
                        allowEventIDFallback: true
                    ) else {
                        continue
                    }
                    let output = (
                        stringifyValue(
                            contentData["message"]
                                ?? contentData["text"]
                                ?? contentData["error"]
                                ?? contentData["output"]
                        ) ?? "后台任务已中止"
                    ).trimmingCharacters(in: .whitespacesAndNewlines)

                    var existing = toolMap[taskId] ?? CLIMessage.ToolUse(
                        id: taskId,
                        name: knownToolNames[taskId] ?? "BackgroundTask",
                        input: nil,
                        output: nil,
                        status: .pending,
                        executionTime: nil,
                        description: nil,
                        permission: nil
                    )
                    if !output.isEmpty {
                        existing.output = output
                    }
                    existing.status = .error
                    toolMap[taskId] = existing
                    knownToolNames[taskId] = existing.name

                    if !output.isEmpty {
                        contentBlocks.append(
                            CLIMessage.ContentBlock(
                                type: .toolResult,
                                text: output,
                                toolUseId: taskId,
                                toolName: existing.name,
                                toolInput: nil,
                                uuid: uuid,
                                parentUUID: parentUUID
                            )
                        )
                    }

                case "tool_use", "tool-call", "tool_call", "toolcall", "tool.call":
                    let rawToolId = (contentData["toolUseId"] as? String)
                        ?? (contentData["tool_use_id"] as? String)
                        ?? (contentData["toolCallId"] as? String)
                        ?? (contentData["tool_call_id"] as? String)
                        ?? (contentData["callId"] as? String)
                        ?? (contentData["id"] as? String)
                        ?? UUID().uuidString
                    let explicitToolName = firstNonEmptyStringFromAny([
                        contentData["toolName"],
                        contentData["name"],
                        nestedValue(contentData, path: ["_meta", "claudeCode", "toolName"]),
                        contentData["kind"],
                        contentData["title"]
                    ])
                    let toolName = resolveToolName(
                        explicit: explicitToolName,
                        contentData: contentData,
                        knownToolNames: knownToolNames,
                        candidateIds: [rawToolId]
                    )
                    let inputString = normalizedToolInputPayloadString(
                        contentData["toolInput"]
                            ?? contentData["rawInput"]
                            ?? contentData["input"]
                            ?? contentData["params"]
                            ?? contentData["arguments"]
                            ?? contentData["payload"]
                    )
                    let toolId = rawToolId
                    let description = contentData["description"] as? String
                    let permission = parsePermission(from: contentData["permission"], fallbackId: toolId)
                    let lifecycleStatus = parseToolLifecycleStatus(contentData["status"] ?? contentData["state"])
                    let normalizedStatus: CLIMessage.ToolUse.Status = {
                        switch lifecycleStatus {
                        case .success:
                            return .success
                        case .error:
                            return .error
                        case .pending:
                            return .running
                        case .running:
                            return .running
                        case nil:
                            return .running
                        }
                    }()

                    toolMap[toolId] = CLIMessage.ToolUse(
                        id: toolId,
                        name: toolName,
                        input: inputString,
                        output: nil,
                        status: normalizedStatus,
                        executionTime: nil,
                        description: description,
                        permission: permission
                    )
                    knownToolNames[toolId] = toolName
                    contentBlocks.append(
                        CLIMessage.ContentBlock(
                            type: .toolUse,
                            text: nil,
                            toolUseId: toolId,
                            toolName: toolName,
                            toolInput: inputString.map { ["_raw": $0] },
                            uuid: uuid,
                            parentUUID: parentUUID
                        )
                    )

                case "permission_request", "permission.request", "request.permission",
                     "protocol.request.permission", "protocol.permission.request":
                    let toolId = (contentData["toolUseId"] as? String)
                        ?? (contentData["tool_use_id"] as? String)
                        ?? (contentData["toolCallId"] as? String)
                        ?? (contentData["tool_call_id"] as? String)
                        ?? (contentData["permissionId"] as? String)
                        ?? (contentData["permission_id"] as? String)
                        ?? UUID().uuidString
                    let toolName = resolveToolName(
                        explicit: firstNonEmptyStringFromAny([
                            contentData["toolName"],
                            contentData["name"],
                            "Permission"
                        ]),
                        contentData: contentData,
                        knownToolNames: knownToolNames,
                        candidateIds: [toolId]
                    )
                    let inputString = normalizedToolInputPayloadString(contentData["toolInput"] ?? contentData["options"])
                    let description = contentData["description"] as? String

                    let fallbackReason = firstNonEmptyStringFromAny([
                        contentData["reason"],
                        contentData["message"],
                        contentData["text"],
                        contentData["description"]
                    ])
                    let permission = parsePermission(
                        from: contentData["permission"] ?? contentData["permissions"],
                        fallbackId: toolId
                    ) ?? CLIMessage.ToolUse.Permission(
                        id: toolId,
                        status: .pending,
                        reason: fallbackReason,
                        mode: nil,
                        allowedTools: nil,
                        decision: nil,
                        date: nil
                    )
                    let toolStatus: CLIMessage.ToolUse.Status = {
                        switch permission.status {
                        case .pending:
                            return .running
                        case .approved:
                            return .success
                        case .denied, .canceled:
                            return .error
                        }
                    }()

                    toolMap[toolId] = CLIMessage.ToolUse(
                        id: toolId,
                        name: toolName,
                        input: inputString,
                        output: nil,
                        status: toolStatus,
                        executionTime: nil,
                        description: description,
                        permission: permission
                    )
                    knownToolNames[toolId] = toolName

                    contentBlocks.append(
                        CLIMessage.ContentBlock(
                            type: .toolUse,
                            text: nil,
                            toolUseId: toolId,
                            toolName: toolName,
                            toolInput: inputString.map { ["_raw": $0] },
                            uuid: uuid,
                            parentUUID: parentUUID
                        )
                    )

                case "tool_result", "tool-result", "toolresult", "tool-call-result", "tool_call_result", "tool_result_error",
                     "tool.call.update", "tool_call_update", "tool-call-update":
                    let rawToolIdCandidate = (contentData["toolUseId"] as? String)
                        ?? (contentData["tool_use_id"] as? String)
                        ?? (contentData["toolCallId"] as? String)
                        ?? (contentData["tool_call_id"] as? String)
                        ?? (contentData["callId"] as? String)
                        ?? (contentData["id"] as? String)
                    let output = (
                        stringifyValue(
                            contentData["text"]
                                ?? contentData["rawOutput"]
                                ?? contentData["output"]
                                ?? contentData["result"]
                                ?? contentData["content"]
                        ) ?? ""
                    )
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let inputString = normalizedToolInputPayloadString(
                        contentData["toolInput"]
                            ?? contentData["rawInput"]
                            ?? contentData["input"]
                            ?? contentData["params"]
                            ?? contentData["arguments"]
                            ?? contentData["payload"]
                    )
                    let isTerminalChunk = (contentData["terminalChunk"] as? Bool) ?? false
                    let lifecycleStatus = parseToolLifecycleStatus(contentData["status"] ?? contentData["state"])
                    let isError = ((contentData["isError"] as? Bool) ?? (contentData["is_error"] as? Bool) ?? false) || rawType == "tool_result_error"
                    let explicitToolName = firstNonEmptyStringFromAny([
                        contentData["toolName"],
                        contentData["name"],
                        nestedValue(contentData, path: ["_meta", "claudeCode", "toolName"]),
                        contentData["kind"],
                        contentData["title"]
                    ])
                    let inferredToolName = resolveToolNameOrNil(
                        explicit: explicitToolName,
                        contentData: contentData,
                        knownToolNames: knownToolNames,
                        candidateIds: [rawToolIdCandidate].compactMap { $0 }
                    )
                    var resolvedToolId = rawToolIdCandidate
                    if let id = resolvedToolId,
                       toolMap[id] == nil,
                       knownToolNames[id] == nil {
                        resolvedToolId = nil
                    }
                    if resolvedToolId == nil {
                        resolvedToolId = findMatchingRunningToolID(
                            toolName: inferredToolName,
                            in: toolMap
                        )
                    }
                    let rawToolId = rawToolIdCandidate ?? resolvedToolId ?? UUID().uuidString
                    let toolId = resolvedToolId ?? rawToolId
                    let permission = parsePermission(from: contentData["permission"], fallbackId: toolId)
                    let resolvedToolName: String = {
                        return resolveToolName(
                            explicit: explicitToolName,
                            contentData: contentData,
                            knownToolNames: knownToolNames,
                            candidateIds: [toolId, rawToolId]
                        )
                    }()
                    let hasKnownToolContext = (toolMap[toolId] != nil)
                        || (knownToolNames[toolId] != nil)
                        || (toolMap[rawToolId] != nil)
                        || (knownToolNames[rawToolId] != nil)
                        || (resolvedToolName != "tool")
                    let metaToolResponse = nestedValue(contentData, path: ["_meta", "claudeCode", "toolResponse"])
                    let hasContentArray = ((contentData["content"] as? [Any])?.isEmpty == false)

                    // Claude metadata-only progress updates carry no renderable signal.
                    if rawType == "tool.call.update" || rawType == "tool_call_update" || rawType == "tool-call-update",
                       output.isEmpty,
                       inputString == nil,
                       lifecycleStatus == nil,
                       !hasContentArray,
                       permission == nil,
                       metaToolResponse != nil {
                        continue
                    }

                    if output.isEmpty,
                       inputString == nil,
                       !isError,
                       lifecycleStatus == nil,
                       permission == nil,
                       !hasKnownToolContext {
                        continue
                    }

                    var existing = toolMap[toolId] ?? CLIMessage.ToolUse(
                        id: toolId,
                        name: resolvedToolName,
                        input: nil,
                        output: nil,
                        status: .pending,
                        executionTime: nil,
                        description: nil,
                        permission: nil
                    )
                    let existingInputEmpty = existing.input?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
                    if existingInputEmpty, let inputString {
                        existing.input = inputString
                    } else if existingInputEmpty {
                        if let compactInput = compactCommandInputPayload(output),
                           !compactInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            existing.input = compactInput
                        } else if let command = extractCommandPreviewFromPayload(output),
                                  !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            existing.input = command
                        }
                    }
                    if !output.isEmpty {
                        if isTerminalChunk,
                           let current = existing.output,
                           !current.isEmpty {
                            existing.output = current + output
                        } else {
                            existing.output = output
                        }
                    }
                    if let lifecycleStatus {
                        existing.status = lifecycleStatus
                    } else if isError {
                        existing.status = .error
                    } else if !output.isEmpty {
                        if isTerminalChunk {
                            existing.status = .running
                        } else {
                            existing.status = .success
                        }
                    }
                    if let permission {
                        existing.permission = permission
                    }
                    toolMap[toolId] = existing
                    knownToolNames[toolId] = existing.name
                    knownToolNames[rawToolId] = existing.name

                    if !output.isEmpty {
                        contentBlocks.append(
                            CLIMessage.ContentBlock(
                                type: .toolResult,
                                text: output,
                                toolUseId: toolId,
                                toolName: existing.name,
                                toolInput: nil,
                                uuid: uuid,
                                parentUUID: parentUUID
                            )
                        )
                    } else if inputString != nil
                        && (rawType == "tool.call.update" || rawType == "tool_call_update" || rawType == "tool-call-update") {
                        contentBlocks.append(
                            CLIMessage.ContentBlock(
                                type: .toolUse,
                                text: nil,
                                toolUseId: toolId,
                                toolName: existing.name,
                                toolInput: existing.input.map { ["_raw": $0] },
                                uuid: uuid,
                                parentUUID: parentUUID
                            )
                        )
                    }

                default:
                    if isSilentProtocolEvent(
                        rawType: rawType,
                        contentData: contentData,
                        codexOptimizationsEnabled: codexOptimizationsEnabled
                    ) {
                        continue
                    }

                    let fallbackId = (contentData["id"] as? String) ?? uuid ?? UUID().uuidString
                    let fallbackName = "protocol.\(rawType)"
                    let payloadText = stringifyValue(contentData)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let fallbackText = payloadText.isEmpty
                        ? "[未适配协议事件] \(rawType)"
                        : "[未适配协议事件] \(rawType)\n\(payloadText)"

                    toolMap[fallbackId] = CLIMessage.ToolUse(
                        id: fallbackId,
                        name: fallbackName,
                        input: nil,
                        output: fallbackText,
                        status: .success,
                        executionTime: nil,
                        description: "未适配协议事件（兜底渲染）",
                        permission: nil
                    )
                    knownToolNames[fallbackId] = fallbackName

                    contentBlocks.append(
                        CLIMessage.ContentBlock(
                            type: .toolResult,
                            text: fallbackText,
                            toolUseId: fallbackId,
                            toolName: fallbackName,
                            toolInput: nil,
                            uuid: uuid,
                            parentUUID: parentUUID
                        )
                    )
                }
            }
        }

        if contentBlocks.isEmpty,
           let text = data["content"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            contentBlocks = [
                CLIMessage.ContentBlock(
                    type: .text,
                    text: text,
                    toolUseId: nil,
                    toolName: nil,
                    toolInput: nil,
                    uuid: nil,
                    parentUUID: nil
                )
            ]
        }

        guard !contentBlocks.isEmpty || !toolMap.isEmpty else {
            return nil
        }

        let timestamp: Date
        if let timestampMs = data["timestamp"] as? Double {
            timestamp = Date(timeIntervalSince1970: timestampMs / 1000.0)
        } else if let timestampInt = data["timestamp"] as? Int {
            timestamp = Date(timeIntervalSince1970: Double(timestampInt) / 1000.0)
        } else {
            timestamp = Date()
        }

        let seq = (data["seq"] as? Int)
        let runId = (data["runId"] as? String)
            ?? contentBlocks.compactMap { $0.uuid }.first
        let parentRunId = (data["parentRunId"] as? String)
            ?? contentBlocks.compactMap { $0.parentUUID }.first
        let isSidechain = (data["isSidechain"] as? Bool) ?? false

        return CLIMessage(
            id: id,
            role: role,
            content: contentBlocks,
            timestamp: timestamp,
            toolUse: toolMap.isEmpty ? nil : toolMap.values.sorted { $0.id < $1.id },
            rawMessageId: rawMessageId,
            rawSeq: seq,
            runId: runId,
            parentRunId: parentRunId,
            isSidechain: isSidechain,
            selectedSkillName: selectedSkillContext.name,
            selectedSkillUri: selectedSkillContext.uri
        )
    }

    nonisolated private static func resolveToolName(
        explicit: String?,
        contentData: [String: Any],
        knownToolNames: [String: String],
        candidateIds: [String]
    ) -> String {
        resolveToolNameOrNil(
            explicit: explicit,
            contentData: contentData,
            knownToolNames: knownToolNames,
            candidateIds: candidateIds
        ) ?? "tool"
    }

    nonisolated private static func isSilentProtocolEvent(
        rawType: String,
        contentData: [String: Any],
        codexOptimizationsEnabled: Bool
    ) -> Bool {
        guard codexOptimizationsEnabled else { return false }
        return CodexProtocolEventRules.isSilentProtocolEvent(
            rawType: rawType,
            contentData: contentData
        )
    }

    nonisolated private static func isSilentProtocolEventText(
        _ text: String,
        codexOptimizationsEnabled: Bool
    ) -> Bool {
        guard codexOptimizationsEnabled else { return false }
        return CodexProtocolEventRules.isSilentProtocolEventText(text)
    }

    nonisolated private static func isStatusOnlyProtocolFallbackText(
        _ text: String,
        codexOptimizationsEnabled: Bool
    ) -> Bool {
        guard codexOptimizationsEnabled else { return false }
        return CodexProtocolEventRules.isStatusOnlyProtocolFallbackText(text)
    }

    nonisolated private static func isSilentStatusTool(
        _ tool: CLIMessage.ToolUse,
        codexOptimizationsEnabled: Bool
    ) -> Bool {
        guard codexOptimizationsEnabled else { return false }
        return CodexProtocolEventRules.isSilentStatusTool(name: tool.name, output: tool.output)
    }

    nonisolated private static func isDisplayRelevantMessage(_ message: CLIMessage) -> Bool {
        if message.role == .user {
            return true
        }

        if let tools = message.toolUse, !tools.isEmpty {
            return true
        }

        return message.content.contains { block in
            guard let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return false }
            return !isPlaceholderToolToken(text)
        }
    }

    nonisolated private static func resolveToolNameOrNil(
        explicit: String?,
        contentData: [String: Any],
        knownToolNames: [String: String],
        candidateIds: [String]
    ) -> String? {
        if let explicit = sanitizeToolNameCandidate(explicit) {
            return explicit
        }

        for id in candidateIds {
            if let known = sanitizeToolNameCandidate(knownToolNames[id]) {
                return known
            }
        }

        return inferToolNameFromContent(contentData)
    }

    nonisolated private static func sanitizeToolNameCandidate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = normalizeToolIdentifier(trimmed)
        let lowered = normalized.lowercased()
        if lowered == "tool" || lowered == "unknown" || lowered == "null" {
            return nil
        }
        return normalized
    }

    nonisolated private static func normalizeToolIdentifier(_ value: String) -> String {
        var candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("functions.") {
            candidate = String(candidate.dropFirst("functions.".count))
        }
        if candidate.hasPrefix("functions/") {
            candidate = String(candidate.dropFirst("functions/".count))
        }
        return candidate
    }

    nonisolated private static func inferToolNameFromContent(_ contentData: [String: Any]) -> String? {
        if let nestedMetaToolName = sanitizeToolNameCandidate(
            nestedValue(contentData, path: ["_meta", "claudeCode", "toolName"]) as? String
        ) {
            return nestedMetaToolName
        }

        for key in ["tool", "method", "recipient_name", "recipientName", "action", "kind", "title"] {
            if let named = sanitizeToolNameCandidate(contentData[key] as? String) {
                return named
            }
        }

        for nestedKey in ["toolInput", "input", "params", "parameters", "payload", "data"] {
            if let nested = contentData[nestedKey] as? [String: Any] {
                for key in ["tool", "name", "method", "recipient_name", "recipientName"] {
                    if let named = sanitizeToolNameCandidate(nested[key] as? String) {
                        return named
                    }
                }
            }
        }

        let payloadText = stringifyValue(
            contentData["toolInput"]
                ?? contentData["input"]
                ?? contentData["output"]
                ?? contentData["content"]
        ) ?? ""
        if looksLikeTodoListPayload(payloadText) {
            return "TodoWrite"
        }
        if isLikelyBackgroundTaskID(extractTaskIdentifier(from: payloadText)) {
            return "BackgroundTask"
        }
        if looksLikeCommandPayload(payloadText) {
            return "bash"
        }

        return nil
    }

    nonisolated private static func nestedValue(_ root: [String: Any], path: [String]) -> Any? {
        guard let first = path.first else { return nil }
        if path.count == 1 {
            return root[first]
        }
        guard let nested = root[first] as? [String: Any] else {
            return nil
        }
        return nestedValue(nested, path: Array(path.dropFirst()))
    }

    nonisolated private static func extractSelectedSkillContext(
        from root: [String: Any]
    ) -> (name: String?, uri: String?) {
        let name = firstNonEmptyStringFromAny([
            root["skillSelectedName"],
            root["selectedSkillName"],
            root["skillIntent"],
            nestedValue(root, path: ["metadata", "skillSelectedName"]),
            nestedValue(root, path: ["metadata", "selectedSkillName"]),
            nestedValue(root, path: ["metadata", "skillIntent"]),
            nestedValue(root, path: ["metadata", "additionalMetadata", "skillSelectedName"]),
            nestedValue(root, path: ["metadata", "additionalMetadata", "selectedSkillName"]),
            nestedValue(root, path: ["additionalMetadata", "skillSelectedName"]),
            nestedValue(root, path: ["additionalMetadata", "selectedSkillName"])
        ])

        let uri = firstNonEmptyStringFromAny([
            root["skillSelectedUri"],
            root["selectedSkillUri"],
            nestedValue(root, path: ["metadata", "skillSelectedUri"]),
            nestedValue(root, path: ["metadata", "selectedSkillUri"]),
            nestedValue(root, path: ["metadata", "additionalMetadata", "skillSelectedUri"]),
            nestedValue(root, path: ["metadata", "additionalMetadata", "selectedSkillUri"]),
            nestedValue(root, path: ["additionalMetadata", "skillSelectedUri"]),
            nestedValue(root, path: ["additionalMetadata", "selectedSkillUri"])
        ])

        return (name: name, uri: uri)
    }

    nonisolated private static func parseToolLifecycleStatus(_ value: Any?) -> CLIMessage.ToolUse.Status? {
        guard let raw = firstNonEmptyStringFromAny([value])?.lowercased() else {
            return nil
        }

        if ["error", "failed", "failure", "aborted", "cancelled", "canceled", "denied"].contains(raw) {
            return .error
        }
        if ["completed", "complete", "done", "success", "ok"].contains(raw) {
            return .success
        }
        if ["running", "in_progress", "active", "started", "pending", "queued", "waiting"].contains(raw) {
            return .running
        }
        return nil
    }

    nonisolated private static func parsePermission(from raw: Any?, fallbackId: String) -> CLIMessage.ToolUse.Permission? {
        guard let dict = raw as? [String: Any] else { return nil }

        let rawStatus = (dict["status"] as? String)?.lowercased()
        let status: CLIMessage.ToolUse.Permission.PermissionStatus
        switch rawStatus {
        case "approved":
            status = .approved
        case "denied":
            status = .denied
        case "canceled", "cancelled", "abort":
            status = .canceled
        case "pending":
            status = .pending
        default:
            status = .pending
        }

        let permissionId = (dict["id"] as? String) ?? fallbackId
        let reason = dict["reason"] as? String
        let mode = dict["mode"] as? String
        let allowedTools = dict["allowedTools"] as? [String]
        let decision = dict["decision"] as? String

        let date: Double? = {
            if let value = dict["date"] as? Double { return value }
            if let value = dict["date"] as? Int { return Double(value) }
            if let value = dict["date"] as? NSNumber { return value.doubleValue }
            if let value = dict["date"] as? String, let parsed = Double(value) { return parsed }
            return nil
        }()

        return CLIMessage.ToolUse.Permission(
            id: permissionId,
            status: status,
            reason: reason,
            mode: mode,
            allowedTools: allowedTools,
            decision: decision,
            date: date
        )
    }

    nonisolated private static func normalizedToolInputPayloadString(_ value: Any?) -> String? {
        guard let raw = stringifyValue(value)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty else {
            return nil
        }

        if isLowSignalToolInputPayload(raw) {
            return nil
        }

        return raw
    }

    nonisolated private static func isLowSignalToolInputPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }

        let lowered = trimmed.lowercased()
        if lowered == "{}" || lowered == "[]" || lowered == "null" {
            return true
        }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return false
        }

        if let array = json as? [Any] {
            return array.isEmpty
        }

        guard let dict = json as? [String: Any] else { return false }
        if dict.isEmpty { return true }

        let normalizedKeys = Set(dict.keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        let onlyContainerKeys: Set<String> = ["items", "entries", "data", "content"]
        if normalizedKeys.isSubset(of: onlyContainerKeys) {
            return dict.values.allSatisfy { value in
                if let list = value as? [Any] { return list.isEmpty }
                if let string = value as? String { return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                if let nested = value as? [String: Any] { return nested.isEmpty }
                return false
            }
        }

        return false
    }

    nonisolated private static func stringifyValue(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let string = value as? String {
            return string
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return String(describing: value)
    }

    nonisolated private static func isBackgroundTaskToolName(_ name: String?) -> Bool {
        CLIToolSemantics.isBackgroundTaskName(name)
    }

    nonisolated private static func isBackgroundTaskEventToolName(_ name: String?) -> Bool {
        CLIToolSemantics.isBackgroundTaskEventName(name)
    }

    nonisolated private static func normalizedNonEmptyString(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    nonisolated private static func resolveBackgroundTaskIdentifier(
        contentData: [String: Any],
        messageRunId: String?,
        messageParentRunId: String?,
        blockUUID: String?,
        payloadCandidates: [String?] = [],
        allowEventIDFallback: Bool
    ) -> String? {
        let explicitTaskIDs = [
            normalizedNonEmptyString(contentData["taskId"]),
            normalizedNonEmptyString(contentData["task_id"]),
            normalizedNonEmptyString(contentData["taskID"])
        ]
        if let explicit = explicitTaskIDs.compactMap({ $0 }).first {
            return explicit
        }

        for payload in payloadCandidates {
            guard let candidate = extractStructuredTaskIdentifier(from: payload) else { continue }
            if candidate == messageRunId
                || candidate == messageParentRunId
                || isLikelyBackgroundTaskID(candidate) {
                return candidate
            }
        }

        let runScopedIDs = [
            normalizedNonEmptyString(contentData["turn_id"]),
            normalizedNonEmptyString(contentData["turnId"]),
            normalizedNonEmptyString(contentData["thread_id"]),
            normalizedNonEmptyString(contentData["threadId"]),
            messageRunId,
            messageParentRunId
        ]
        if let runScoped = runScopedIDs
            .compactMap({ $0 })
            .first(where: { isLikelyBackgroundTaskID($0) }) {
            return runScoped
        }

        let callScopedIDs = [
            normalizedNonEmptyString(contentData["toolUseId"]),
            normalizedNonEmptyString(contentData["tool_use_id"]),
            normalizedNonEmptyString(contentData["toolCallId"]),
            normalizedNonEmptyString(contentData["tool_call_id"]),
            normalizedNonEmptyString(contentData["callId"])
        ]
        if let callScoped = callScopedIDs
            .compactMap({ $0 })
            .first(where: { isLikelyBackgroundTaskID($0) }) {
            return callScoped
        }

        if allowEventIDFallback,
           let eventID = normalizedNonEmptyString(contentData["id"]),
           isLikelyBackgroundTaskID(eventID) {
            return eventID
        }

        if let blockUUID = normalizedNonEmptyString(blockUUID),
           isLikelyBackgroundTaskID(blockUUID) {
            return blockUUID
        }
        return nil
    }

    nonisolated private static func extractStructuredTaskIdentifier(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        return extractStructuredTaskIdentifier(from: json)
    }

    nonisolated private static func extractStructuredTaskIdentifier(from value: Any) -> String? {
        if let dict = value as? [String: Any] {
            let direct = [
                normalizedNonEmptyString(dict["taskId"]),
                normalizedNonEmptyString(dict["task_id"]),
                normalizedNonEmptyString(dict["turn_id"]),
                normalizedNonEmptyString(dict["turnId"])
            ].compactMap { $0 }
            if let first = direct.first {
                return first
            }

            for nestedKey in ["payload", "input", "output", "data", "params", "arguments", "result", "content"] {
                if let nested = dict[nestedKey],
                   let candidate = extractStructuredTaskIdentifier(from: nested) {
                    return candidate
                }
            }
            return nil
        }

        if let array = value as? [Any] {
            for item in array {
                if let candidate = extractStructuredTaskIdentifier(from: item) {
                    return candidate
                }
            }
        }

        return nil
    }

    nonisolated private static func isLikelyBackgroundTaskID(_ id: String?) -> Bool {
        guard let id else { return false }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }
        if trimmed.hasPrefix("bg_")
            || trimmed.hasPrefix("bg-")
            || trimmed.hasPrefix("task_")
            || trimmed.hasPrefix("task-")
            || trimmed.hasPrefix("turn_")
            || trimmed.hasPrefix("turn-")
            || trimmed.hasPrefix("run_")
            || trimmed.hasPrefix("run-") {
            return true
        }

        if trimmed.range(of: #"(^|[^a-z0-9])(bg_[a-z0-9._:-]+)([^a-z0-9]|$)"#, options: .regularExpression) != nil {
            return true
        }
        if trimmed.range(of: #"(^|[^a-z0-9])(task[_-][a-z0-9._:-]+)([^a-z0-9]|$)"#, options: .regularExpression) != nil {
            return true
        }

        return false
    }

    nonisolated private static func extractTaskIdentifier(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data, options: []),
           let dict = json as? [String: Any] {
            let candidate = (dict["taskId"] as? String)
                ?? (dict["task_id"] as? String)
                ?? (dict["turn_id"] as? String)
                ?? (dict["turnId"] as? String)
                ?? {
                    let hasTaskContext = dict["task"] != nil
                        || dict["taskId"] != nil
                        || dict["task_id"] != nil
                        || dict["state"] != nil
                        || dict["status"] != nil
                    return hasTaskContext ? (dict["id"] as? String) : nil
                }()
            let value = candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty {
                return value
            }
        }

        let patterns = [
            #"(?i)\btask[_\s-]*id\b\s*[:=]\s*`?([A-Za-z0-9._:-]+)`?"#,
            #"(?i)\bturn[_\s-]*id\b\s*[:=]\s*`?([A-Za-z0-9._:-]+)`?"#,
            #"(?i)\|\s*task[_\s-]*id\s*\|\s*`?([A-Za-z0-9._:-]+)`?\s*\|"#,
            #"(?i)\btask_id\s*=\s*\"([^\"]+)\""#,
            #"(?i)\b(bg_[A-Za-z0-9._:-]+)\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: trimmed) else {
                continue
            }
            let value = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
    }

    nonisolated private static func backgroundTaskLifecycleStatus(
        from raw: String,
        isError: Bool
    ) -> CLIMessage.ToolUse.Status? {
        if isError {
            return .error
        }

        let lowered = raw.lowercased()
        if lowered.contains("status | **running**")
            || lowered.contains("status: running")
            || lowered.contains("\"status\":\"running\"")
            || lowered.contains("\"state\":\"running\"")
            || lowered.contains("background task launched") {
            return .running
        }
        if lowered.contains("cancelled")
            || lowered.contains("canceled")
            || lowered.contains("aborted")
            || lowered.contains("\"status\":\"cancelled\"")
            || lowered.contains("\"status\":\"canceled\"") {
            // cancellation is terminal but not necessarily a failure in UX
            return .success
        }
        if lowered.contains("failed")
            || lowered.contains("error")
            || lowered.contains("\"status\":\"failed\"")
            || lowered.contains("\"status\":\"error\"") {
            return .error
        }
        if lowered.contains("completed")
            || lowered.contains("finished")
            || lowered.contains("succeeded")
            || lowered.contains("\"status\":\"completed\"")
            || lowered.contains("\"state\":\"completed\"")
            || lowered.contains("task completed successfully") {
            return .success
        }
        return nil
    }

    nonisolated private static func looksLikeTodoListPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.hasPrefix("[") else { return false }

        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data),
              let list = json as? [[String: Any]],
              !list.isEmpty else {
            return false
        }

        let matched = list.filter { item in
            let hasContent = (item["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            let hasStatus = item["status"] != nil
            let hasPriority = item["priority"] != nil
            return hasContent && (hasStatus || hasPriority)
        }
        return !matched.isEmpty
    }

    nonisolated private static func findMatchingRunningToolID(
        toolName: String?,
        in toolMap: [String: CLIMessage.ToolUse]
    ) -> String? {
        let normalizedTarget = toolName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        guard !normalizedTarget.isEmpty else { return nil }

        let candidates = toolMap.values.filter { tool in
            let normalizedName = tool.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard normalizedName == normalizedTarget else { return false }
            return tool.status == .running || tool.status == .pending
        }

        guard candidates.count == 1 else { return nil }
        return candidates.first?.id
    }

    nonisolated private static func sanitizeMessagePayload(
        _ message: CLIMessage,
        agentId: String? = nil,
        sessionId: String? = nil,
        mode: PayloadSanitizationMode = .persist,
        codexOptimizationsEnabled: Bool = false
    ) -> CLIMessage {
        let sourceTools = message.toolUse ?? []
        let suppressedToolIDs = Set(
            sourceTools
                .filter { isSilentStatusTool($0, codexOptimizationsEnabled: codexOptimizationsEnabled) }
                .map(\.id)
        )

        let sanitizedToolsList: [CLIMessage.ToolUse] = sourceTools
            .filter { !suppressedToolIDs.contains($0.id) }
            .map {
            sanitizeToolPayload(
                $0,
                messageId: message.id,
                agentId: agentId,
                sessionId: sessionId,
                mode: mode
            )
        }
        let sanitizedTools: [CLIMessage.ToolUse]? = sanitizedToolsList.isEmpty ? nil : sanitizedToolsList
        let hasTools = !sanitizedToolsList.isEmpty
        let sanitizedContent: [CLIMessage.ContentBlock] = message.content.compactMap { block in
            if let toolUseId = block.toolUseId,
               suppressedToolIDs.contains(toolUseId) {
                return nil
            }

            guard let text = block.text else { return block }

            if hasTools, block.type == .toolResult {
                return nil
            }

            let compactText = sanitizeInlineText(text)
            if compactText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nil
            }
            if block.type == .event,
               isSilentProtocolEventText(
                compactText,
                codexOptimizationsEnabled: codexOptimizationsEnabled
               ) {
                return nil
            }
            if (block.type == .event || block.type == .toolResult),
               isStatusOnlyProtocolFallbackText(
                compactText,
                codexOptimizationsEnabled: codexOptimizationsEnabled
               ) {
                return nil
            }
            if message.role == .assistant {
                if codexOptimizationsEnabled,
                   shouldDropAssistantPayloadText(compactText, hasTools: hasTools) {
                    return nil
                }
                if codexOptimizationsEnabled, isLikelyPlanningScratchText(compactText) {
                    return nil
                }
            }

            return CLIMessage.ContentBlock(
                type: block.type,
                text: compactText,
                toolUseId: block.toolUseId,
                toolName: block.toolName,
                toolInput: block.toolInput,
                uuid: block.uuid,
                parentUUID: block.parentUUID
            )
        }

        return CLIMessage(
            id: message.id,
            role: message.role,
            content: sanitizedContent,
            timestamp: message.timestamp,
            toolUse: sanitizedTools,
            rawMessageId: message.rawMessageId,
            rawSeq: message.rawSeq,
            runId: message.runId,
            parentRunId: message.parentRunId,
            isSidechain: message.isSidechain,
            selectedSkillName: message.selectedSkillName,
            selectedSkillUri: message.selectedSkillUri
        )
    }

    private struct ToolPayloadProjection {
        let inlineText: String?
        let ref: String?
        let size: Int?
    }

    private enum PayloadSanitizationMode {
        case display
        case persist

        var allowsSidecarWrite: Bool {
            self == .persist
        }

        var allowsSidecarRead: Bool {
            self == .persist
        }

        var prefersInlinePayload: Bool {
            self == .display
        }
    }

    nonisolated private static func sanitizeToolPayload(
        _ tool: CLIMessage.ToolUse,
        messageId: String,
        agentId: String?,
        sessionId: String?,
        mode: PayloadSanitizationMode
    ) -> CLIMessage.ToolUse {
        var value = tool
        value.input = compactToolField(tool.input)
        value.output = compactToolField(tool.output)

        let inputProjection = projectToolPayloadField(
            raw: tool.input,
            existingRef: tool.inputPayloadRef,
            existingSize: tool.inputPayloadSize,
            messageId: messageId,
            toolId: tool.id,
            toolName: tool.name,
            direction: "input",
            agentId: agentId,
            sessionId: sessionId,
            toolStatus: tool.status,
            mode: mode
        )
        value.input = inputProjection.inlineText
        value.inputPayloadRef = inputProjection.ref
        value.inputPayloadSize = inputProjection.size

        let outputProjection = projectToolPayloadField(
            raw: tool.output,
            existingRef: tool.outputPayloadRef,
            existingSize: tool.outputPayloadSize,
            messageId: messageId,
            toolId: tool.id,
            toolName: tool.name,
            direction: "output",
            agentId: agentId,
            sessionId: sessionId,
            toolStatus: tool.status,
            mode: mode
        )
        value.output = outputProjection.inlineText
        value.outputPayloadRef = outputProjection.ref
        value.outputPayloadSize = outputProjection.size
        return value
    }

    nonisolated private static func projectToolPayloadField(
        raw: String?,
        existingRef: String?,
        existingSize: Int?,
        messageId: String,
        toolId: String,
        toolName: String,
        direction: String,
        agentId: String?,
        sessionId: String?,
        toolStatus: CLIMessage.ToolUse.Status,
        mode: PayloadSanitizationMode
    ) -> ToolPayloadProjection {
        guard let raw else {
            return ToolPayloadProjection(inlineText: nil, ref: existingRef, size: existingSize)
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ToolPayloadProjection(inlineText: nil, ref: existingRef, size: existingSize)
        }

        let charCount = trimmed.count
        let lineCount = trimmed.utf8.reduce(into: 1) { count, value in
            if value == 10 { count += 1 }
        }
        let isSkillTool = isSkillManagementToolName(toolName)

        if let existingRef, !existingRef.isEmpty {
            let isCommandInputField = direction == "input"
                && (isCommandLikeToolName(toolName) || looksLikeCommandPayload(trimmed))

            if mode.prefersInlinePayload {
                if isCommandInputField {
                    if let compactInput = compactCommandInputPayload(trimmed) {
                        return ToolPayloadProjection(
                            inlineText: compactInput,
                            ref: existingRef,
                            size: existingSize ?? charCount
                        )
                    }
                    if let sidecar = readToolPayloadSidecar(ref: existingRef),
                       let compactInput = compactCommandInputPayload(sidecar) {
                        return ToolPayloadProjection(
                            inlineText: compactInput,
                            ref: existingRef,
                            size: existingSize ?? charCount
                        )
                    }
                }

                return ToolPayloadProjection(
                    inlineText: isSkillTool ? preferredInlineSkillPayload(trimmed) : compactToolField(trimmed),
                    ref: existingRef,
                    size: existingSize ?? charCount
                )
            }

            let effectiveCharCount = existingSize ?? charCount
            let isCommandOutput = direction == "output"
                && (isCommandLikeToolName(toolName) || looksLikeCommandPayload(trimmed))
            let isCommandInput = direction == "input"
                && (isCommandLikeToolName(toolName) || looksLikeCommandPayload(trimmed))
            let todoSummary: String? = {
                if let inline = summarizedTodoProgressPayload(trimmed) {
                    return inline
                }
                guard direction == "output",
                      mode.allowsSidecarRead,
                      shouldAttemptTodoSummaryFromSidecar(toolName: toolName),
                      let sidecar = readToolPayloadSidecar(ref: existingRef) else {
                    return nil
                }
                return summarizedTodoProgressPayload(sidecar)
            }()
            return ToolPayloadProjection(
                inlineText: isCommandOutput
                    ? summarizedCommandOutputPayload(trimmed, charCount: effectiveCharCount, lineCount: lineCount)
                    : (isCommandInput
                        ? summarizedCommandInputPayload(
                            trimmed,
                            charCount: effectiveCharCount,
                            lineCount: lineCount,
                            fallbackRef: existingRef
                        )
                        : (todoSummary ?? summarizedToolPayload(
                            trimmed,
                            charCount: effectiveCharCount,
                            lineCount: lineCount,
                            previewLimit: shouldAggressivelyExternalize(toolName: toolName) ? 180 : 280
                        ))),
                ref: existingRef,
                size: effectiveCharCount
            )
        }

        let isTransientStatus = toolStatus == .running || toolStatus == .pending
        if mode.prefersInlinePayload || isTransientStatus || !mode.allowsSidecarWrite {
            return ToolPayloadProjection(
                inlineText: isSkillTool ? preferredInlineSkillPayload(trimmed) : compactToolField(trimmed),
                ref: nil,
                size: charCount
            )
        }

        let aggressive = shouldAggressivelyExternalize(toolName: toolName)
        let isCommandOutput = direction == "output"
            && (isCommandLikeToolName(toolName) || looksLikeCommandPayload(trimmed))
        let isCommandInput = direction == "input"
            && (isCommandLikeToolName(toolName) || looksLikeCommandPayload(trimmed))
        let forceSidecarForHeavyToolOutput = shouldForceSidecarForHeavyToolOutput(
            toolName: toolName,
            direction: direction
        )
        let charThreshold = aggressive ? 1200 : 2200
        let lineThreshold = aggressive ? 40 : 70
        // Command output should preserve full details in the detail sheet.
        // Externalize at a lower threshold so medium outputs don't get inline-trimmed.
        let commandCharThreshold = 700
        let commandLineThreshold = 24
        let shouldExternalize = isCommandOutput
            || forceSidecarForHeavyToolOutput
            || charCount > charThreshold
            || lineCount > lineThreshold
            || (isCommandOutput && (charCount > commandCharThreshold || lineCount > commandLineThreshold))
        guard shouldExternalize,
              let agentId,
              let sessionId else {
            return ToolPayloadProjection(inlineText: compactToolField(trimmed), ref: nil, size: charCount)
        }

        if let ref = writeToolPayloadSidecar(
            content: trimmed,
            messageId: messageId,
            toolId: toolId,
            direction: direction,
            agentId: agentId,
            sessionId: sessionId
        ) {
            let summary: String
            if isCommandOutput {
                summary = summarizedCommandOutputPayload(
                    trimmed,
                    charCount: charCount,
                    lineCount: lineCount
                )
            } else if isCommandInput {
                summary = summarizedCommandInputPayload(
                    trimmed,
                    charCount: charCount,
                    lineCount: lineCount
                )
            } else {
                summary = summarizedTodoProgressPayload(trimmed)
                    ?? summarizedToolPayload(
                        trimmed,
                        charCount: charCount,
                        lineCount: lineCount,
                        previewLimit: aggressive ? 180 : 280
                    )
            }
            return ToolPayloadProjection(inlineText: summary, ref: ref, size: charCount)
        }

        return ToolPayloadProjection(inlineText: compactToolField(trimmed), ref: nil, size: charCount)
    }

    nonisolated private static func shouldForceSidecarForHeavyToolOutput(
        toolName: String,
        direction: String
    ) -> Bool {
        guard direction == "output" else { return false }
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }

        if CLIToolSemantics.isReadName(normalized)
            || CLIToolSemantics.isSearchLikeName(normalized)
            || CLIToolSemantics.isGlobName(normalized) {
            return true
        }

        return normalized.contains("list_files")
            || normalized.contains("listfiles")
            || normalized.contains("grep")
            || normalized.contains("find")
            || normalized.contains("search")
            || normalized.contains("read")
            || normalized.contains("glob")
    }

    nonisolated private static func shouldAggressivelyExternalize(toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("bash")
            || normalized.contains("command")
            || normalized.contains("shell")
            || normalized.contains("read")
            || normalized.contains("grep")
            || normalized.contains("glob")
            || normalized.contains("search")
            || normalized.contains("webfetch")
            || normalized.contains("task")
            || normalized.contains("patch")
            || normalized.contains("edit")
            || normalized.contains("write")
    }

    nonisolated private static func isCommandLikeToolName(_ toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("bash")
            || normalized.contains("command")
            || normalized.contains("shell")
            || normalized.contains("terminal")
            || normalized.contains("exec")
            || normalized == "execute"
    }

    nonisolated private static func isSkillManagementToolName(_ toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        guard normalized.contains("skill") else { return false }
        return normalized.contains("list")
            || normalized.contains("get")
            || normalized.contains("create")
            || normalized.contains("delete")
    }

    nonisolated private static func preferredInlineSkillPayload(_ text: String) -> String {
        // Keep skill payload mostly intact in display mode, otherwise skill cards
        // cannot extract id/name/description from long argument JSON.
        if text.count <= 100_000 {
            return text
        }
        let prefix = String(text.prefix(12_000))
        return "\(prefix)\n…[skill payload trimmed \(text.count) chars]"
    }

    nonisolated private static func shouldAttemptTodoSummaryFromSidecar(toolName: String) -> Bool {
        let normalized = toolName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.isEmpty || normalized == "tool" || normalized == "unknown" {
            return true
        }
        return CLIToolSemantics.isTodoName(normalized) || CLIToolSemantics.isTaskLikeName(normalized)
    }

    nonisolated private static func looksLikeCommandPayload(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("\"command\"")
            || lowered.contains("\"cmd\"")
            || lowered.contains("\"parsed_cmd\"")
            || lowered.contains("\"script\"")
            || lowered.contains("\"stdout\"")
            || lowered.contains("\"stderr\"")
            || lowered.contains("\"exit_code\"")
            || lowered.contains("\"exitcode\"")
            || lowered.contains("\"aggregated_output\"")
            || lowered.contains("\"formatted_output\"")
            || lowered.contains("\"processid\"")
            || lowered.contains("\"process_id\"")
    }

    nonisolated private static func summarizedTodoProgressPayload(_ text: String) -> String? {
        let items = todoItemsFromPayload(text)
        guard !items.isEmpty else { return nil }

        let total = items.count
        let inProgress = items.filter { $0.status == "in_progress" }.count
        let pending = items.filter { $0.status == "pending" }.count
        let completed = items.filter { $0.status == "completed" }.count

        return "Todo: \(total) 项（进行中 \(inProgress) / 待办 \(pending) / 已完成 \(completed)）"
    }

    nonisolated private static func todoItemsFromPayload(_ text: String) -> [(content: String, status: String)] {
        let candidates = todoJSONCandidates(from: text)
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let entries = todoEntries(from: json),
                  !entries.isEmpty else {
                continue
            }

            let items = entries.compactMap { entry -> (content: String, status: String)? in
                guard let content = todoEntryContent(from: entry) else { return nil }
                let status = normalizeTodoStatusForSummary((entry["status"] as? String) ?? "pending")
                return (content, status)
            }

            if !items.isEmpty {
                return items
            }
        }
        return []
    }

    nonisolated private static func todoJSONCandidates(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var candidates: [String] = []
        func appendCandidate(_ value: String?) {
            guard let value else { return }
            let candidate = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !candidate.isEmpty else { return }
            if !candidates.contains(candidate) {
                candidates.append(candidate)
            }
        }

        appendCandidate(trimmed)

        if trimmed.hasPrefix("```"),
           let fenceStart = trimmed.firstIndex(of: "\n"),
           let fenceEnd = trimmed.range(of: "```", options: .backwards),
           fenceStart < fenceEnd.lowerBound {
            let inner = String(trimmed[trimmed.index(after: fenceStart)..<fenceEnd.lowerBound])
            appendCandidate(inner)
        }

        if let bracketStart = trimmed.firstIndex(of: "["),
           let bracketEnd = trimmed.lastIndex(of: "]"),
           bracketStart < bracketEnd {
            appendCandidate(String(trimmed[bracketStart...bracketEnd]))
        }

        return candidates
    }

    nonisolated private static func todoEntries(from root: Any) -> [[String: Any]]? {
        func looksLikeTodoDict(_ dict: [String: Any]) -> Bool {
            dict["content"] != nil
                || dict["title"] != nil
                || dict["text"] != nil
                || dict["task"] != nil
                || dict["status"] != nil
                || dict["priority"] != nil
        }

        var queue: [Any] = [root]
        var cursor = 0
        var scanned = 0
        let maxNodes = 1024

        while cursor < queue.count && scanned < maxNodes {
            let current = queue[cursor]
            cursor += 1
            scanned += 1

            if let array = current as? [Any] {
                let dictArray = array.compactMap { $0 as? [String: Any] }
                if !dictArray.isEmpty && dictArray.contains(where: looksLikeTodoDict) {
                    return dictArray
                }
                queue.append(contentsOf: array)
                continue
            }

            guard let dict = current as? [String: Any] else { continue }
            for key in ["todos", "items", "data", "content", "output", "result", "payload", "entries"] {
                if let value = dict[key] {
                    queue.append(value)
                }
            }
        }

        return nil
    }

    nonisolated private static func todoEntryContent(from entry: [String: Any]) -> String? {
        for key in ["content", "title", "text", "task", "name", "summary"] {
            if let value = entry[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }
        return nil
    }

    nonisolated private static func normalizeTodoStatusForSummary(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "in_progress", "in-progress", "running", "active":
            return "in_progress"
        case "done", "completed", "complete", "success":
            return "completed"
        case "pending", "todo", "queued", "open":
            return "pending"
        default:
            return key.isEmpty ? "pending" : key
        }
    }

    nonisolated private static func summarizedToolPayload(
        _ text: String,
        charCount: Int,
        lineCount: Int,
        previewLimit: Int
    ) -> String {
        let preview = String(text.prefix(previewLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = preview.isEmpty ? "(空输出)" : preview
        return "\(body)\n…[内容较大，点击详情按需加载全文 \(charCount) chars / \(lineCount) lines]"
    }

    nonisolated private static func summarizedCommandOutputPayload(
        _ text: String,
        charCount: Int,
        lineCount: Int
    ) -> String {
        let previewLine = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        let preview = previewLine.map { String($0.prefix(120)) }
        let previewPrefix = preview.map { "\($0)\n" } ?? ""

        let lower = text.lowercased()
        let patterns = [
            #""exit[_ ]?code"\s*:\s*(-?\d+)"#,
            #""exitcode"\s*:\s*(-?\d+)"#
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
               let match = regex.firstMatch(in: lower, options: [], range: NSRange(location: 0, length: lower.utf16.count)),
               match.numberOfRanges > 1,
               let range = Range(match.range(at: 1), in: lower) {
                let code = String(lower[range])
                return "\(previewPrefix)…[命令结果已外置（exit=\(code)，\(charCount) chars / \(lineCount) lines）]"
            }
        }

        return "\(previewPrefix)…[命令结果已外置（\(charCount) chars / \(lineCount) lines）]"
    }

    nonisolated private static func summarizedCommandInputPayload(
        _ text: String,
        charCount: Int,
        lineCount: Int,
        fallbackRef: String? = nil
    ) -> String {
        if let compactInput = compactCommandInputPayload(text) {
            return compactInput
        }

        if let command = extractCommandPreviewFromPayload(text),
           !command.isEmpty {
            return command
        }
        if let fallbackRef,
           let sidecar = readToolPayloadSidecar(ref: fallbackRef) {
            if let compactInput = compactCommandInputPayload(sidecar) {
                return compactInput
            }
            if let command = extractCommandPreviewFromPayload(sidecar),
               !command.isEmpty {
                return command
            }
        }
        return "命令参数已外置（\(charCount) chars / \(lineCount) lines）"
    }

    nonisolated private static func compactCommandInputPayload(_ raw: String) -> String? {
        guard let json = parseJSONObject(raw) else { return nil }

        let source = firstNonEmptyStringFromAny([
            json["source"],
            json["commandSource"],
            json["command_source"]
        ])

        let command = extractCommandValueFromAny(
            json["command"]
                ?? json["cmd"]
                ?? json["script"]
                ?? json["request"]
                ?? json["payload"]
        )

        let actions = extractCommandActionObjects(from: json)
        let compactActions: [[String: Any]] = actions.prefix(24).compactMap { item in
            guard let rawType = firstNonEmptyStringFromAny([
                item["type"],
                item["kind"],
                item["action"]
            ]) else {
                return nil
            }
            let type = normalizeCommandActionType(rawType)
            guard !type.isEmpty else { return nil }

            var compact: [String: Any] = ["type": type]
            if let cmd = firstNonEmptyStringFromAny([item["cmd"], item["command"], item["script"]]) {
                compact["cmd"] = String(cmd.prefix(200))
            }
            if let path = firstNonEmptyStringFromAny([item["path"], item["file"], item["filePath"]]) {
                compact["path"] = String(path.prefix(200))
            }
            if let name = firstNonEmptyStringFromAny([item["name"], item["target"]]) {
                compact["name"] = String(name.prefix(120))
            }
            if let query = firstNonEmptyStringFromAny([item["query"], item["pattern"], item["keyword"]]) {
                compact["query"] = String(query.prefix(160))
            }
            return compact
        }

        guard source != nil || command != nil || !compactActions.isEmpty else {
            return nil
        }

        var payload: [String: Any] = [:]
        if let source {
            payload["source"] = source
        }
        if let command {
            payload["command"] = String(command.prefix(240))
        }
        if !compactActions.isEmpty {
            payload["parsed_cmd"] = compactActions
        }

        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    nonisolated private static func extractCommandActionObjects(from json: [String: Any]) -> [[String: Any]] {
        let directKeys = ["parsed_cmd", "parsedCmd", "commandActions", "command_actions", "actions"]
        for key in directKeys {
            if let list = json[key] as? [[String: Any]], !list.isEmpty {
                return list
            }
        }

        for containerKey in ["request", "payload", "input", "params", "parameters", "data"] {
            guard let nested = json[containerKey] as? [String: Any] else { continue }
            for key in directKeys {
                if let list = nested[key] as? [[String: Any]], !list.isEmpty {
                    return list
                }
            }
        }

        return []
    }

    nonisolated private static func normalizeCommandActionType(_ raw: String) -> String {
        let key = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        if key == "list" || key == "listfiles" {
            return "list_files"
        }
        return key
    }

    nonisolated private static func firstNonEmptyStringFromAny(_ values: [Any?]) -> String? {
        for value in values {
            guard let value else { continue }
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
                continue
            }
            if let number = value as? NSNumber {
                let stringValue = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !stringValue.isEmpty {
                    return stringValue
                }
            }
        }
        return nil
    }

    nonisolated private static func extractCommandPreviewFromPayload(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let json = parseJSONObject(trimmed),
           let command = extractCommandValueFromAny(json),
           !command.isEmpty {
            return command
        }

        let patterns = [
            #"(?:["']?(?:command|cmd|script)["']?)\s*:\s*"([^"]+)""#,
            #"(?:["']?(?:command|cmd|script)["']?)\s*:\s*'([^']+)'"#,
            #"(?:["']?(?:command|cmd|script)["']?)\s*:\s*([^,\}\n]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, options: [], range: nsRange) else { continue }
            for index in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: index), in: trimmed) else { continue }
                let value = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty && value != "null" {
                    return value
                }
            }
        }

        return nil
    }

    nonisolated private static func parseJSONObject(_ raw: String) -> [String: Any]? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return nil
        }
        return dict
    }

    nonisolated private static func readToolPayloadSidecar(ref: String) -> String? {
        let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRef.isEmpty else { return nil }

        let fileManager = FileManager.default
        let candidates: [URL] = {
            if trimmedRef.hasPrefix("/") {
                return [URL(fileURLWithPath: trimmedRef)]
            }

            guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return [URL(fileURLWithPath: trimmedRef)]
            }

            let sessionsRoot = docs.appendingPathComponent("sessions", isDirectory: true)
            var urls: [URL] = []
            urls.append(sessionsRoot.appendingPathComponent(trimmedRef))
            urls.append(docs.appendingPathComponent(trimmedRef))

            if trimmedRef.hasPrefix("sessions/") {
                let dropped = String(trimmedRef.dropFirst("sessions/".count))
                urls.append(sessionsRoot.appendingPathComponent(dropped))
                urls.append(docs.appendingPathComponent(dropped))
            }

            if let usersRange = trimmedRef.range(of: "users/") {
                let suffix = String(trimmedRef[usersRange.lowerBound...])
                urls.append(sessionsRoot.appendingPathComponent(suffix))
                urls.append(docs.appendingPathComponent(suffix))
            }

            return urls
        }()

        for url in candidates {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }

        return nil
    }

    nonisolated private static func extractCommandValueFromAny(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        if let list = value as? [Any] {
            let parts = list.compactMap { extractCommandValueFromAny($0) }
            if let unwrapped = unwrapShellInvocation(parts) {
                return unwrapped
            }
            let joined = parts
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? nil : joined
        }

        if let dict = value as? [String: Any] {
            if let parsed = extractCommandValueFromAny(
                dict["parsed_cmd"] ?? dict["parsedCmd"] ?? dict["actions"]
            ), !parsed.isEmpty {
                return parsed
            }
            for key in [
                "command", "cmd", "script",
                "executable", "program", "binary",
                "args", "arguments",
                "parameters", "params", "request", "payload", "data",
                "text", "value"
            ] {
                if let extracted = extractCommandValueFromAny(dict[key]), !extracted.isEmpty {
                    return extracted
                }
            }
        }

        return nil
    }

    nonisolated private static func unwrapShellInvocation(_ tokens: [String]) -> String? {
        guard tokens.count >= 3 else { return nil }
        guard isShellLauncherToken(tokens[0]) else { return nil }

        for flag in ["-lc", "-c", "/c", "-command", "-Command"] {
            if let index = tokens.firstIndex(of: flag),
               index + 1 < tokens.count {
                let command = tokens[(index + 1)...]
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty {
                    return command
                }
            }
        }

        return nil
    }

    nonisolated private static func isShellLauncherToken(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return false }
        let leaf = URL(fileURLWithPath: token).lastPathComponent.lowercased()
        return leaf == "sh"
            || leaf == "bash"
            || leaf == "zsh"
            || leaf == "fish"
            || leaf == "pwsh"
            || leaf == "powershell"
            || leaf == "cmd.exe"
    }

    nonisolated private static func writeToolPayloadSidecar(
        content: String,
        messageId: String,
        toolId: String,
        direction: String,
        agentId: String,
        sessionId: String
    ) -> String? {
        let fileManager = FileManager.default
        guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }

        let sessionsRoot = docs.appendingPathComponent("sessions", isDirectory: true)
        let sessionRelativePath = SessionStorageLayout.sessionRelativePath(agentId: agentId, sessionId: sessionId)
        let safeMessageId = SessionStorageLayout.encodePathComponent(messageId)
        let safeToolId = SessionStorageLayout.encodePathComponent(toolId)
        let fileName = "\(safeMessageId)_\(safeToolId).\(direction).txt"
        let relativeRef = "\(sessionRelativePath)/tool_payloads/\(fileName)"

        let absoluteURL = sessionsRoot.appendingPathComponent(relativeRef)
        do {
            let dirURL = absoluteURL.deletingLastPathComponent()
            try fileManager.createDirectory(at: dirURL, withIntermediateDirectories: true)
            try content.write(to: absoluteURL, atomically: true, encoding: .utf8)
            return relativeRef
        } catch {
            return nil
        }
    }

    nonisolated private static func compactToolField(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lineCount = trimmed.utf8.reduce(into: 1) { count, value in
            if value == 10 { count += 1 }
        }
        if trimmed.count <= 600 && lineCount <= 24 {
            return trimmed
        }

        let prefix = String(trimmed.prefix(260))
        return "\(prefix)\n…[payload trimmed \(trimmed.count) chars / \(lineCount) lines]"
    }

    nonisolated private static func sanitizeInlineText(_ raw: String) -> String {
        let filtered = stripPlaceholderToolLines(from: raw)
        let trimmed = filtered.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Keep assistant final response intact; tool payload suppression is handled
        // by shouldDropAssistantPayloadText + tool sidecar externalization.
        return trimmed
    }

    nonisolated private static func shouldDropAssistantPayloadText(_ text: String, hasTools: Bool) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        if isPlaceholderToolToken(trimmed) {
            return true
        }
        if isLikelyPlanningScratchText(trimmed) {
            return true
        }
        guard hasTools else { return false }
        let lowered = trimmed.lowercased()

        if lowered.contains("tool result (id:") ||
            lowered.contains("\"toolname\"") ||
            lowered.contains("\"callid\"") ||
            lowered.contains("\"parsed_cmd\"") ||
            lowered.contains("\"stdout\"") ||
            lowered.contains("\"stderr\"") ||
            lowered.contains("<content>") ||
            lowered.contains("</content>") {
            return true
        }

        let looksLikeJSON = trimmed.hasPrefix("{")
            || trimmed.hasPrefix("[")
            || trimmed.hasPrefix("```json")
            || trimmed.hasPrefix("```JSON")
        if looksLikeJSON && trimmed.count > 1000 {
            return true
        }
        return false
    }

    // MARK: - Local + remote loading

    private func loadMessagesFromLocal() async {
        guard let contextGoSessionId = resolvedContextGoSessionId else {
            messages = []
            localLoadedTailCount = 0
            canLoadOlderLocalMessages = false
            return
        }

        do {
            let cachedMessages = try await sessionRepository.getCachedMessagesTail(
                sessionId: contextGoSessionId,
                limit: localMessagePageSize,
                beforeTailCount: 0
            )
            localLoadedTailCount = cachedMessages.count
            canLoadOlderLocalMessages = cachedMessages.count == localMessagePageSize

            let decoded = await decodeStoredMessagesInBackground(cachedMessages)
            let sorted = decoded.sorted(by: Self.messageSortLessThan)
            messages = dedupeCodexUserMessages(in: sorted)

            let localSeqValues = messages.compactMap { $0.rawSeq }
            let localMaxSeq = localSeqValues.max() ?? 0
            let hasAnyRawSeq = !localSeqValues.isEmpty
            if hasAnyRawSeq {
                // Use local highest seq as the only incremental cursor.
                // Avoid jumping to session.seq, otherwise we may skip missing updates.
                lastSyncedSeq = localMaxSeq
            } else {
                // Legacy cache without seq must force catch-up from server.
                lastSyncedSeq = 0
            }
            rebuildKnownToolNames()
            refreshActiveTodoSnapshot()
            refreshRuntimeStateTitle()
        } catch {
            print("[CLISessionViewModel] Failed to load repository messages: \(error)")
            canLoadOlderLocalMessages = false
        }
    }

    func loadOlderLocalMessagesIfNeeded() async {
        guard !isLoadingOlderLocalMessages, canLoadOlderLocalMessages else { return }
        guard let contextGoSessionId = resolvedContextGoSessionId else { return }

        isLoadingOlderLocalMessages = true
        defer { isLoadingOlderLocalMessages = false }

        do {
            let batch = try await sessionRepository.getCachedMessagesTail(
                sessionId: contextGoSessionId,
                limit: localMessagePageSize,
                beforeTailCount: localLoadedTailCount
            )
            localLoadedTailCount += batch.count
            canLoadOlderLocalMessages = batch.count == localMessagePageSize

            let decoded = await decodeStoredMessagesInBackground(batch)
            guard !decoded.isEmpty else { return }

            let existingIds = Set(messages.map(\.id))
            let unique = decoded.filter { !existingIds.contains($0.id) }
            guard !unique.isEmpty else { return }

            if let newestLoaded = unique.last?.timestamp,
               let oldestExisting = messages.first?.timestamp,
               newestLoaded <= oldestExisting {
                messages.insert(contentsOf: unique, at: 0)
            } else {
                messages.append(contentsOf: unique)
                messages.sort(by: Self.messageSortLessThan)
            }
            messages = dedupeCodexUserMessages(in: messages)
            for message in unique {
                captureKnownToolNames(from: message)
            }
            refreshActiveTodoSnapshot()
            refreshRuntimeStateTitle()
        } catch {
            print("[CLISessionViewModel] Failed to load older local messages: \(error)")
        }
    }

    func syncMessagesFromRemote(forceFull: Bool) async {
        guard !isSyncingRemoteMessages else { return }
        guard !remoteSessionMissing else { return }

        isSyncingRemoteMessages = true
        defer { isSyncingRemoteMessages = false }

        do {
            let localMaxSeq = max(lastSyncedSeq, messages.compactMap { $0.rawSeq }.max() ?? 0)

            if !forceFull || !hasSyncedAgentStateFromRemote {
                if let latestSession = try? await client.fetchSession(sessionId: session.id) {
                    remoteSessionMissing = false
                    applyAgentStatePermissions(
                        latestSession.agentState,
                        version: latestSession.agentStateVersion
                    )
                    hasSyncedAgentStateFromRemote = true

                    if !forceFull && latestSession.seq <= localMaxSeq && !messages.isEmpty {
                        // Server seq has not advanced; skip fetch loop to avoid idle polling churn.
                        lastSyncedSeq = max(lastSyncedSeq, localMaxSeq)
                        return
                    }
                }
            }

            // Force-full replay must start from seq=0 to fetch the full timeline.
            // Using nil would trigger v2 backward mode (latest window only) and
            // can miss early messages such as the initial user prompt.
            var sinceSeq: Int? = forceFull ? 0 : localMaxSeq
            var hasMore = true
            var loops = 0
            var stalledCursorLoops = 0
            let syncDeadline = Date().addingTimeInterval(2.5)
            let maxSyncLoopsPerRun = 8

            while hasMore && loops < maxSyncLoopsPerRun {
                let previousSinceSeq = sinceSeq ?? 0
                let batch = try await client.fetchDecodedMessages(sessionId: session.id, sinceSeq: sinceSeq)
                let nextSinceSeq = batch.nextSinceSeq > 0 ? batch.nextSinceSeq : previousSinceSeq
                let cursorAdvanced = nextSinceSeq > previousSinceSeq

                if batch.messages.isEmpty && !cursorAdvanced {
                    // Prevent tight loops when server keeps returning hasMore=true with no progress.
                    break
                }

                let parsedBatch = await parseIncomingPayloadsInBackground(batch.messages)
                mergeKnownToolNames(parsedBatch.knownToolNames)
                applyIncomingMessages(parsedBatch.messages)

                sinceSeq = nextSinceSeq > 0 ? nextSinceSeq : sinceSeq
                if let sinceSeq {
                    lastSyncedSeq = max(lastSyncedSeq, sinceSeq)
                }

                if cursorAdvanced {
                    stalledCursorLoops = 0
                } else {
                    stalledCursorLoops += 1
                }

                if stalledCursorLoops >= 2 {
                    // Server cursor is not moving; stop sync to avoid sustained CPU churn.
                    break
                }

                hasMore = batch.hasMore
                loops += 1

                if Date() >= syncDeadline {
                    // Keep sync responsive; avoid spending too long in one foreground run.
                    break
                }
            }
        } catch {
            if isRemoteSessionMissingError(error) {
                remoteSessionMissing = true
                return
            }
            print("[CLISessionViewModel] Remote sync failed: \(error)")
        }
    }

    private func isRemoteSessionMissingError(_ error: Error) -> Bool {
        let lowered = error.localizedDescription.lowercased()
        return lowered.contains("session not found")
            || lowered.contains("\"error\":\"session not found\"")
    }

    private func appendMessageIfNeeded(_ message: CLIMessage) {
        applyIncomingMessages([message])
    }

    private func applyIncomingMessages(_ incoming: [CLIMessage]) {
        guard !incoming.isEmpty else { return }

        var workingMessages = messages
        var changedById: [String: CLIMessage] = [:]
        var mutatedExistingMessage = false
        var appendedMessages: [CLIMessage] = []

        for message in incoming {
            if let seq = message.rawSeq {
                lastSyncedSeq = max(lastSyncedSeq, seq)
            }

            if shouldDropDuplicateCodexUserProjection(message, in: workingMessages) {
                continue
            }

            let previousCount = workingMessages.count
            if let changed = upsertMessage(message, in: &workingMessages) {
                changedById[changed.id] = changed
                if workingMessages.count > previousCount {
                    appendedMessages.append(changed)
                } else {
                    mutatedExistingMessage = true
                }
            }
        }

        guard !changedById.isEmpty else { return }

        let shouldSort: Bool = {
            guard !mutatedExistingMessage else { return true }
            guard !appendedMessages.isEmpty else { return false }
            guard Self.isMessageOrderSorted(appendedMessages) else { return true }

            let latestExistingTimestamp: Date = messages.last?.timestamp ?? .distantPast
            guard let firstAppendedTimestamp = appendedMessages.first?.timestamp else {
                return false
            }
            return firstAppendedTimestamp < latestExistingTimestamp
        }()

        if shouldSort {
            workingMessages.sort(by: Self.messageSortLessThan)
        }
        workingMessages = dedupeCodexUserMessages(in: workingMessages)
        messages = workingMessages

        let changedMessages = changedById.values.sorted(by: Self.messageSortLessThan)
        for message in changedMessages {
            captureKnownToolNames(from: message)
        }
        refreshActiveTodoSnapshot()
        refreshRuntimeStateTitle()
        persistMessages(changedMessages)
    }

    private func dedupeCodexUserMessages(in input: [CLIMessage]) -> [CLIMessage] {
        guard isCodexSession else { return input }
        guard input.count > 1 else { return input }

        var result: [CLIMessage] = []
        result.reserveCapacity(input.count)
        let dedupeWindow: TimeInterval = 120

        for message in input {
            guard message.role == .user else {
                result.append(message)
                continue
            }

            let text = Self.normalizedUserMessageText(message.displayText)
            guard !text.isEmpty else {
                result.append(message)
                continue
            }

            let incomingIdentifier = message.rawMessageId ?? message.id
            let incomingIsUUID = Self.isUUIDLikeIdentifier(incomingIdentifier)
            guard let existingIndex = result.lastIndex(where: { existing in
                guard existing.role == .user else { return false }
                let existingText = Self.normalizedUserMessageText(existing.displayText)
                guard existingText == text else { return false }

                let existingIdentifier = existing.rawMessageId ?? existing.id
                let existingIsUUID = Self.isUUIDLikeIdentifier(existingIdentifier)
                guard existingIsUUID != incomingIsUUID else { return false }

                return abs(existing.timestamp.timeIntervalSince(message.timestamp)) <= dedupeWindow
            }) else {
                result.append(message)
                continue
            }

            let existingIdentifier = result[existingIndex].rawMessageId ?? result[existingIndex].id
            let existingIsUUID = Self.isUUIDLikeIdentifier(existingIdentifier)
            if incomingIsUUID && !existingIsUUID {
                result[existingIndex] = message
            }
        }

        return result
    }

    private func shouldDropDuplicateCodexUserProjection(
        _ incoming: CLIMessage,
        in storage: [CLIMessage]
    ) -> Bool {
        guard isCodexSession else { return false }
        guard incoming.role == .user else { return false }

        let incomingText = Self.normalizedUserMessageText(incoming.displayText)
        guard !incomingText.isEmpty else { return false }
        guard !Self.isUUIDLikeIdentifier(incoming.rawMessageId ?? incoming.id) else { return false }

        // Codex may emit both:
        // 1) real user message (role=user, local UUID id)
        // 2) projected user_message/usermessage event (non-UUID id)
        // Keep the concrete local user message and suppress the projection.
        let dedupeWindow: TimeInterval = 120
        for existing in storage where existing.role == .user {
            let existingText = Self.normalizedUserMessageText(existing.displayText)
            guard existingText == incomingText else { continue }
            guard Self.isUUIDLikeIdentifier(existing.rawMessageId ?? existing.id) else { continue }
            if abs(existing.timestamp.timeIntervalSince(incoming.timestamp)) <= dedupeWindow {
                return true
            }
        }
        return false
    }

    nonisolated private static func normalizedUserMessageText(_ text: String) -> String {
        text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    nonisolated private static func isUUIDLikeIdentifier(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    nonisolated private static func isMessageOrderSorted(_ values: [CLIMessage]) -> Bool {
        guard values.count > 1 else { return true }
        for index in 1..<values.count {
            if messageSortLessThan(values[index], values[index - 1]) {
                return false
            }
        }
        return true
    }

    nonisolated private static func messageSortLessThan(_ lhs: CLIMessage, _ rhs: CLIMessage) -> Bool {
        if let lhsSeq = lhs.rawSeq, let rhsSeq = rhs.rawSeq, lhsSeq != rhsSeq {
            return lhsSeq < rhsSeq
        }

        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }

        if let lhsSeq = lhs.rawSeq, let rhsSeq = rhs.rawSeq, lhsSeq != rhsSeq {
            return lhsSeq < rhsSeq
        }
        if lhs.rawSeq != nil || rhs.rawSeq != nil {
            return lhs.rawSeq != nil
        }

        let lhsRawId = lhs.rawMessageId ?? lhs.id
        let rhsRawId = rhs.rawMessageId ?? rhs.id
        if lhsRawId != rhsRawId {
            return lhsRawId < rhsRawId
        }
        return lhs.id < rhs.id
    }

    private func upsertMessage(_ message: CLIMessage, in storage: inout [CLIMessage]) -> CLIMessage? {
        if let index = permissionPlaceholderMatchIndex(for: message, in: storage) {
            let merged = mergePermissionPlaceholder(existing: storage[index], incoming: message)
            guard storage[index] != merged else { return nil }
            storage[index] = merged
            return merged
        }

        if let index = storage.firstIndex(where: { $0.id == message.id }) {
            let merged = mergeMessageSkillContext(existing: storage[index], incoming: message)
            guard storage[index] != merged else { return nil }
            storage[index] = merged
            return merged
        }

        if let rawId = message.rawMessageId,
           !rawId.isEmpty,
           let index = storage.firstIndex(where: { $0.rawMessageId == rawId }) {
            let merged = mergeMessageSkillContext(existing: storage[index], incoming: message)
            guard storage[index] != merged else { return nil }
            storage[index] = merged
            return merged
        }

        storage.append(message)
        return message
    }

    private func mergeMessageSkillContext(existing: CLIMessage, incoming: CLIMessage) -> CLIMessage {
        let mergedSkillName = normalizedSkillField(incoming.selectedSkillName)
            ?? normalizedSkillField(existing.selectedSkillName)
        let mergedSkillUri = normalizedSkillField(incoming.selectedSkillUri)
            ?? normalizedSkillField(existing.selectedSkillUri)

        if mergedSkillName == incoming.selectedSkillName,
           mergedSkillUri == incoming.selectedSkillUri {
            return incoming
        }

        return CLIMessage(
            id: incoming.id,
            role: incoming.role,
            content: incoming.content,
            timestamp: incoming.timestamp,
            toolUse: incoming.toolUse,
            rawMessageId: incoming.rawMessageId,
            rawSeq: incoming.rawSeq,
            runId: incoming.runId,
            parentRunId: incoming.parentRunId,
            isSidechain: incoming.isSidechain,
            selectedSkillName: mergedSkillName,
            selectedSkillUri: mergedSkillUri
        )
    }

    private func normalizedSkillField(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func rebuildKnownToolNames() {
        knownToolNames.removeAll()
        for message in messages {
            captureKnownToolNames(from: message)
        }
    }

    private func captureKnownToolNames(from message: CLIMessage) {
        guard let tools = message.toolUse else { return }
        for tool in tools where !tool.name.isEmpty {
            knownToolNames[tool.id] = tool.name
        }
    }

    private func mergeKnownToolNames(_ incoming: [String: String]) {
        guard !incoming.isEmpty else { return }
        for (id, name) in incoming where !name.isEmpty {
            knownToolNames[id] = name
        }
    }

    private func parseIncomingPayloadsInBackground(_ payloads: [[String: Any]]) async -> ParsedPayloadBatch {
        let seedToolNames = knownToolNames
        let currentSessionId = session.id
        let currentAgentId = client.ownerAgentId
        let codexOptimizationsEnabled = isCodexSession
        return await withCheckedContinuation { continuation in
            messageParsingQueue.async {
                var localToolNames = seedToolNames
                var parsedMessages: [CLIMessage] = []
                parsedMessages.reserveCapacity(payloads.count)

                for payload in payloads {
                    if let message = Self.parseMessageDataRaw(
                        payload,
                        knownToolNames: &localToolNames,
                        codexOptimizationsEnabled: codexOptimizationsEnabled
                    ) {
                        let compacted = Self.sanitizeMessagePayload(
                            message,
                            agentId: currentAgentId,
                            sessionId: currentSessionId,
                            mode: .display,
                            codexOptimizationsEnabled: codexOptimizationsEnabled
                        )
                        if Self.isDisplayRelevantMessage(compacted) {
                            parsedMessages.append(compacted)
                        }
                    }
                }

                continuation.resume(
                    returning: ParsedPayloadBatch(
                        messages: parsedMessages,
                        knownToolNames: localToolNames
                    )
                )
            }
        }
    }

    private func decodeStoredMessagesInBackground(_ storedMessages: [SessionMessage]) async -> [CLIMessage] {
        let currentAgentId = client.ownerAgentId
        let codexOptimizationsEnabled = isCodexSession
        return await withCheckedContinuation { continuation in
            messageParsingQueue.async {
                let decoded = storedMessages.compactMap { stored in
                    Self.decodeCLIMessageRaw(
                        stored,
                        agentId: currentAgentId,
                        sessionId: stored.sessionId,
                        codexOptimizationsEnabled: codexOptimizationsEnabled
                    )
                }.filter(Self.isDisplayRelevantMessage)
                continuation.resume(returning: decoded)
            }
        }
    }

    private func permissionPlaceholderMatchIndex(for incoming: CLIMessage, in messages: [CLIMessage]) -> Int? {
        guard let incomingTools = incoming.toolUse, !incomingTools.isEmpty else { return nil }
        guard !hasRuntimeTextContent(incoming) else { return nil }
        let incomingToolIds = Set(incomingTools.map(\.id))

        return messages.firstIndex { message in
            let marker = message.rawMessageId ?? message.id
            guard marker.hasPrefix(permissionPlaceholderPrefix) else { return false }
            guard let tools = message.toolUse else { return false }
            return tools.contains(where: { incomingToolIds.contains($0.id) })
        }
    }

    private func hasRuntimeTextContent(_ message: CLIMessage) -> Bool {
        message.content.contains { block in
            switch block.type {
            case .text, .thinking, .event:
                return !(block.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            case .toolUse, .toolResult:
                return false
            }
        }
    }

    private func mergePermissionPlaceholder(existing: CLIMessage, incoming: CLIMessage) -> CLIMessage {
        var mergedTools: [CLIMessage.ToolUse] = existing.toolUse ?? []
        for tool in incoming.toolUse ?? [] {
            mergeTool(tool, into: &mergedTools)
        }

        let mergedSeq: Int? = {
            if let lhs = existing.rawSeq, let rhs = incoming.rawSeq {
                return max(lhs, rhs)
            }
            return existing.rawSeq ?? incoming.rawSeq
        }()

        return CLIMessage(
            id: existing.id,
            role: existing.role,
            content: existing.content,
            timestamp: existing.timestamp,
            toolUse: mergedTools,
            rawMessageId: existing.rawMessageId ?? existing.id,
            rawSeq: mergedSeq,
            runId: incoming.runId ?? existing.runId,
            parentRunId: incoming.parentRunId ?? existing.parentRunId,
            isSidechain: existing.isSidechain || incoming.isSidechain,
            selectedSkillName: incoming.selectedSkillName ?? existing.selectedSkillName,
            selectedSkillUri: incoming.selectedSkillUri ?? existing.selectedSkillUri
        )
    }

    private func mergeTool(_ incoming: CLIMessage.ToolUse, into tools: inout [CLIMessage.ToolUse]) {
        guard let index = tools.firstIndex(where: { $0.id == incoming.id }) else {
            tools.append(incoming)
            return
        }

        var existing = tools[index]
        if existing.name == "tool", incoming.name != "tool" {
            existing.name = incoming.name
        }
        if (existing.input?.isEmpty ?? true), let input = incoming.input, !input.isEmpty {
            existing.input = input
        }
        if let output = incoming.output, !output.isEmpty {
            existing.output = output
        }
        if (existing.inputPayloadRef?.isEmpty ?? true),
           let inputPayloadRef = incoming.inputPayloadRef,
           !inputPayloadRef.isEmpty {
            existing.inputPayloadRef = inputPayloadRef
        }
        if let outputPayloadRef = incoming.outputPayloadRef,
           !outputPayloadRef.isEmpty {
            existing.outputPayloadRef = outputPayloadRef
        }
        if existing.inputPayloadSize == nil, let inputPayloadSize = incoming.inputPayloadSize {
            existing.inputPayloadSize = inputPayloadSize
        }
        if let outputPayloadSize = incoming.outputPayloadSize {
            existing.outputPayloadSize = outputPayloadSize
        }
        if let description = incoming.description, !description.isEmpty {
            existing.description = description
        }
        existing.status = mergeToolStatus(existing.status, incoming.status)
        if incoming.executionTime != nil {
            existing.executionTime = incoming.executionTime
        }
        if incoming.permission != nil {
            existing.permission = incoming.permission
        }

        tools[index] = existing
    }

    private func mergeToolStatus(_ lhs: CLIMessage.ToolUse.Status, _ rhs: CLIMessage.ToolUse.Status) -> CLIMessage.ToolUse.Status {
        switch rhs {
        case .error:
            return .error
        case .success:
            return lhs == .error ? .error : .success
        case .running:
            return lhs == .pending ? .running : lhs
        case .pending:
            return lhs
        }
    }

    private func refreshActiveTodoSnapshot() {
        activeTodoSnapshot = latestActiveTodoSnapshot()
    }

    private func latestActiveTodoSnapshot() -> TodoRuntimeSnapshot? {
        for message in messages.reversed() {
            guard let tools = message.toolUse else { continue }
            for tool in tools.reversed() where isTodoCarrierToolName(tool.name) {
                guard let snapshot = parseTodoSnapshot(from: tool, updatedAt: message.timestamp) else {
                    // Task/background-task tools may not carry Todo payloads. Skip those instead of
                    // clearing the header indicator with a false negative.
                    continue
                }
                if snapshot.remainingCount > 0 {
                    return snapshot
                }
                // Latest Todo snapshot has no active items; avoid falling back to stale snapshots.
                return nil
            }
        }
        return nil
    }

    private func isTodoCarrierToolName(_ name: String) -> Bool {
        if isTodoToolName(name) {
            return true
        }
        return CLIToolSemantics.isTaskLikeName(name)
    }

    private func isTodoToolName(_ name: String) -> Bool {
        CLIToolSemantics.isTodoName(name)
    }

    private func parseTodoSnapshot(from tool: CLIMessage.ToolUse, updatedAt: Date) -> TodoRuntimeSnapshot? {
        if let inline = parseTodoSnapshot(fromRawPayload: tool.output, updatedAt: updatedAt) {
            return inline
        }
        if let inline = parseTodoSnapshot(fromRawPayload: tool.input, updatedAt: updatedAt) {
            return inline
        }

        let refs = [tool.outputPayloadRef, tool.inputPayloadRef]
        for ref in refs.compactMap({ $0 }) {
            guard let raw = Self.readToolPayloadSidecar(ref: ref) else { continue }
            if let snapshot = parseTodoSnapshot(fromRawPayload: raw, updatedAt: updatedAt) {
                return snapshot
            }
        }

        return nil
    }

    private func parseTodoSnapshot(fromRawPayload raw: String?, updatedAt: Date) -> TodoRuntimeSnapshot? {
        let parsedItems = ToolUseTodoParser.parseItems(from: raw)
        guard !parsedItems.isEmpty else { return nil }

        let items = parsedItems.map { item in
            TodoRuntimeItem(
                id: item.id,
                content: item.content,
                status: ToolUseTodoParser.normalizedStatus(item.status),
                priority: item.priority
            )
        }
        let completedCount = items.filter { $0.status == "completed" }.count

        return TodoRuntimeSnapshot(
            items: items,
            completedCount: completedCount,
            totalCount: items.count,
            updatedAt: updatedAt
        )
    }

    private func settleRunningToolsOnIdleIfNeeded() {
        var changedMessages: [CLIMessage] = []

        for index in messages.indices {
            guard var tools = messages[index].toolUse, !tools.isEmpty else { continue }

            var didChange = false
            for toolIndex in tools.indices {
                guard tools[toolIndex].status == .running else { continue }
                if tools[toolIndex].permission?.status == .pending {
                    continue
                }
                tools[toolIndex].status = .success
                didChange = true
            }

            guard didChange else { continue }
            var updated = messages[index]
            updated.toolUse = tools
            messages[index] = updated
            changedMessages.append(updated)
        }

        guard !changedMessages.isEmpty else { return }
        refreshActiveTodoSnapshot()
        refreshRuntimeStateTitle()
        persistMessages(changedMessages)
    }

    private func applyAgentStatePermissions(
        _ agentState: CLISession.AgentState?,
        version: Int? = nil
    ) {
        guard let agentState else { return }
        if let version, version < authoritativeAgentStateVersion {
            return
        }

        switch agentState.status {
        case .thinking:
            applyAuthoritativeActivityState(.thinking, version: version)
        case .waitingForPermission:
            applyAuthoritativeActivityState(.waitingForPermission, version: version)
        case .idle, .error:
            applyAuthoritativeActivityState(.idle, version: version)
        }

        if let requests = agentState.requests {
            for (permissionId, request) in requests {
                let permission = CLIMessage.ToolUse.Permission(
                    id: permissionId,
                    status: .pending,
                    reason: nil,
                    mode: nil,
                    allowedTools: nil,
                    decision: nil,
                    date: nil
                )
                upsertPermissionTool(
                    permissionId: permissionId,
                    toolName: request.tool,
                    input: request.arguments,
                    permission: permission,
                    status: .running,
                    timestamp: request.createdAt ?? Date()
                )
            }
        }

        if let completed = agentState.completedRequests {
            for (permissionId, request) in completed {
                let resolvedPermissionId = resolveCompletedPermissionTargetID(
                    preferredId: permissionId,
                    toolName: request.tool
                )
                let permissionStatus: CLIMessage.ToolUse.Permission.PermissionStatus = {
                    switch request.status.lowercased() {
                    case "approved":
                        return .approved
                    case "denied":
                        return .denied
                    case "canceled", "cancelled", "abort":
                        return .canceled
                    default:
                        return .pending
                    }
                }()

                let permission = CLIMessage.ToolUse.Permission(
                    id: resolvedPermissionId,
                    status: permissionStatus,
                    reason: request.reason,
                    mode: request.mode,
                    allowedTools: request.allowedTools,
                    decision: request.decision,
                    date: request.completedAt?.timeIntervalSince1970
                )
                let toolStatus: CLIMessage.ToolUse.Status = (permissionStatus == .approved) ? .success : .error
                upsertPermissionTool(
                    permissionId: resolvedPermissionId,
                    toolName: request.tool,
                    input: request.arguments,
                    permission: permission,
                    status: toolStatus,
                    timestamp: request.createdAt ?? request.completedAt ?? Date()
                )
            }
        }
    }

    func refreshBootstrapAgentState(_ agentState: CLISession.AgentState?, version: Int? = nil) {
        applyAgentStatePermissions(agentState, version: version)
        refreshRuntimeStateTitle()
    }

    func applyAuthoritativeSessionStatus(statusRaw: String?, version: Int?) {
        guard let statusRaw else { return }
        switch statusRaw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "thinking":
            applyAuthoritativeActivityState(.thinking, version: version)
        case "waiting_for_permission", "waiting.for.permission":
            applyAuthoritativeActivityState(.waitingForPermission, version: version)
        case "idle", "error":
            applyAuthoritativeActivityState(.idle, version: version)
        default:
            break
        }
    }

    private func upsertPermissionTool(
        permissionId: String,
        toolName: String,
        input: String?,
        permission: CLIMessage.ToolUse.Permission,
        status: CLIMessage.ToolUse.Status,
        timestamp: Date
    ) {
        if permission.status == .pending {
            notifyPermissionRequiredIfNeeded(
                permissionId: permissionId,
                toolName: toolName,
                reason: permission.reason
            )
        }

        if let index = messages.firstIndex(where: { message in
            message.toolUse?.contains(where: { $0.id == permissionId }) == true
        }) {
            let original = messages[index]
            var updated = messages[index]
            var toolList = updated.toolUse ?? []
            if let toolIndex = toolList.firstIndex(where: { $0.id == permissionId }) {
                var tool = toolList[toolIndex]
                if tool.name == "tool", !toolName.isEmpty {
                    tool.name = toolName
                }
                if (tool.input?.isEmpty ?? true), let input, !input.isEmpty {
                    tool.input = input
                }
                tool.permission = permission
                tool.status = mergeToolStatus(tool.status, status)
                if permission.status == .denied || permission.status == .canceled {
                    if tool.output == nil, let reason = permission.reason, !reason.isEmpty {
                        tool.output = reason
                    }
                }
                toolList[toolIndex] = tool
            } else {
                toolList.append(
                    CLIMessage.ToolUse(
                        id: permissionId,
                        name: toolName.isEmpty ? "tool" : toolName,
                        input: input,
                        output: nil,
                        status: status,
                        executionTime: nil,
                        description: nil,
                        permission: permission
                    )
                )
            }

            if !updated.content.contains(where: { $0.type == .toolUse && $0.toolUseId == permissionId }) {
                updated = CLIMessage(
                    id: updated.id,
                    role: updated.role,
                    content: updated.content + [
                        CLIMessage.ContentBlock(
                            type: .toolUse,
                            text: nil,
                            toolUseId: permissionId,
                            toolName: toolName.isEmpty ? "tool" : toolName,
                            toolInput: input.map { ["_raw": $0] } ?? nil,
                            uuid: nil,
                            parentUUID: nil
                        )
                    ],
                    timestamp: updated.timestamp,
                    toolUse: toolList,
                    rawMessageId: updated.rawMessageId,
                    rawSeq: updated.rawSeq,
                    runId: updated.runId,
                    parentRunId: updated.parentRunId,
                    isSidechain: updated.isSidechain
                )
            } else {
                updated.toolUse = toolList
            }

            guard updated != original else { return }

            messages[index] = updated
            captureKnownToolNames(from: updated)
            refreshRuntimeStateTitle()
            persistMessage(updated)
            return
        }

        let placeholderId = "\(permissionPlaceholderPrefix)\(permissionId)"
        let tool = CLIMessage.ToolUse(
            id: permissionId,
            name: toolName.isEmpty ? "tool" : toolName,
            input: input,
            output: (permission.status == .denied || permission.status == .canceled) ? permission.reason : nil,
            status: status,
            executionTime: nil,
            description: nil,
            permission: permission
        )
        let message = CLIMessage(
            id: placeholderId,
            role: .assistant,
            content: [
                CLIMessage.ContentBlock(
                    type: .toolUse,
                    text: nil,
                    toolUseId: permissionId,
                    toolName: tool.name,
                    toolInput: input.map { ["_raw": $0] } ?? nil,
                    uuid: nil,
                    parentUUID: nil
                )
            ],
            timestamp: timestamp,
            toolUse: [tool],
            rawMessageId: placeholderId,
            rawSeq: nil,
            runId: nil,
            parentRunId: nil,
            isSidechain: false
        )
        appendMessageIfNeeded(message)
    }

    private func notifyPermissionRequiredIfNeeded(permissionId: String, toolName: String, reason: String?) {
        let key = "\(session.id):\(permissionId)"
        guard notifiedPendingPermissionKeys.insert(key).inserted else { return }

        CLIPermissionNotificationCenter.shared.notifyPermissionRequired(
            sessionId: session.id,
            permissionId: permissionId,
            toolName: toolName,
            reason: reason
        )
    }

    // MARK: - Actions

    func sendMessage(
        contextGoLinked: Bool? = nil,
        contextGoSpaceIds: [String]? = nil,
        skillAutoLoad: Bool? = nil,
        skillIntent: String? = nil,
        skillSpaceIds: [String]? = nil,
        skillPinnedUris: [String]? = nil,
        selectedSkillUri: String? = nil,
        selectedSkillName: String? = nil
    ) {
        guard !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let resolvedContextGoLinked = resolveContextGoLinked(override: contextGoLinked)
        let resolvedContextGoSpaceIds = resolveContextGoSpaceIds(
            linked: resolvedContextGoLinked,
            override: contextGoSpaceIds
        )
        let resolvedSkillSpaceIds = (skillSpaceIds ?? resolvedContextGoSpaceIds)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let resolvedSkillPinnedUris = (skillPinnedUris ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let resolvedSkillIntent = skillIntent?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSkillIntent = (resolvedSkillIntent?.isEmpty == false) ? resolvedSkillIntent : nil
        let resolvedSelectedSkillUri = selectedSkillUri?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSelectedSkillUri = (resolvedSelectedSkillUri?.isEmpty == false) ? resolvedSelectedSkillUri : nil
        let resolvedSelectedSkillName = selectedSkillName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalSelectedSkillName = (resolvedSelectedSkillName?.isEmpty == false) ? resolvedSelectedSkillName : nil
        let resolvedSkillAutoLoad = skillAutoLoad
            ?? (resolvedContextGoLinked && (!resolvedSkillPinnedUris.isEmpty || !resolvedSkillSpaceIds.isEmpty))

        let messageText = inputText
        let localId = UUID().uuidString
        inputText = ""

        let userMessage = CLIMessage(
            id: localId,
            role: .user,
            content: [
                CLIMessage.ContentBlock(
                    type: .text,
                    text: messageText,
                    toolUseId: nil,
                    toolName: nil,
                    toolInput: nil,
                    uuid: nil,
                    parentUUID: nil
                )
            ],
            timestamp: Date(),
            toolUse: nil,
            rawMessageId: localId,
            rawSeq: nil,
            selectedSkillName: finalSelectedSkillName,
            selectedSkillUri: finalSelectedSkillUri
        )

        appendMessageIfNeeded(userMessage)
        applyEphemeralActivityState(.thinking)
        localTurnPending = true

        Task {
            isSending = true
            syncActivityPresentationFromState()
            refreshRuntimeStateTitle()
            defer {
                isSending = false
                syncActivityPresentationFromState()
                refreshRuntimeStateTitle()
            }

            do {
                var additionalMetadata: [String: Any] = [
                    "contextGoLinked": resolvedContextGoLinked,
                    "spaceIds": resolvedContextGoSpaceIds,
                    "skillAutoLoad": resolvedSkillAutoLoad,
                    "skillSpaceIds": resolvedSkillSpaceIds
                ]
                if let finalSkillIntent {
                    additionalMetadata["skillIntent"] = finalSkillIntent
                }
                if !resolvedSkillPinnedUris.isEmpty {
                    additionalMetadata["skillPinnedUris"] = resolvedSkillPinnedUris
                }
                if let finalSelectedSkillUri {
                    additionalMetadata["skillSelectedUri"] = finalSelectedSkillUri
                }
                if let finalSelectedSkillName {
                    additionalMetadata["skillSelectedName"] = finalSelectedSkillName
                }

                try await client.sendUserMessage(
                    sessionId: session.id,
                    text: messageText,
                    localId: localId,
                    additionalMetadata: additionalMetadata
                )
                await reportInstructionEventToCore(
                    text: messageText,
                    localId: localId,
                    contextGoLinked: resolvedContextGoLinked,
                    contextGoSpaceIds: resolvedContextGoSpaceIds,
                    skillAutoLoad: resolvedSkillAutoLoad,
                    skillIntent: finalSkillIntent,
                    skillSpaceIds: resolvedSkillSpaceIds,
                    skillPinnedUris: resolvedSkillPinnedUris
                )
                await syncMessagesFromRemote(forceFull: false)
            } catch {
                errorMessage = "发送失败: \(error.localizedDescription)"
                showError = true
                localTurnPending = false
                applyEphemeralActivityState(.idle)
            }
        }
    }

    func abortCurrentRun() async {
        guard hasActiveRun else { return }
        guard !isAborting else { return }

        isAborting = true
        syncActivityPresentationFromState()
        refreshRuntimeStateTitle()
        defer {
            isAborting = false
            syncActivityPresentationFromState()
            refreshRuntimeStateTitle()
        }

        do {
            try await client.sessionAbort(sessionId: session.id, timeout: 20)
            markPendingRuntimeWorkAsAborted(reason: "用户停止了任务")
            await reportAbortEventToCore(reason: "user_cancelled")
            appendSystemStatusMessage("用户停止了任务")
            localTurnPending = false
            applyEphemeralActivityState(.idle)
            refreshRuntimeStateTitle()
            await syncMessagesFromRemote(forceFull: false)
        } catch {
            errorMessage = "停止失败: \(error.localizedDescription)"
            showError = true
            await syncMessagesFromRemote(forceFull: false)
            refreshRuntimeStateTitle()
        }
    }

    private func markPendingRuntimeWorkAsAborted(reason: String) {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else { return }

        messages = messages.map { message in
            guard var tools = message.toolUse else { return message }
            var changed = false

            for index in tools.indices {
                if tools[index].status == .pending || tools[index].status == .running {
                    tools[index].status = .error
                    if tools[index].output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                        tools[index].output = trimmedReason
                    }
                    changed = true
                }

                if var permission = tools[index].permission,
                   permission.status == .pending {
                    permission.status = .canceled
                    permission.reason = permission.reason?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
                        ? permission.reason
                        : trimmedReason
                    tools[index].permission = permission
                    changed = true
                }
            }

            guard changed else { return message }
            var updated = message
            updated.toolUse = tools
            return updated
        }
    }

    private func appendSystemStatusMessage(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let messageId = "system-status-\(UUID().uuidString)"
        let statusMessage = CLIMessage(
            id: messageId,
            role: .system,
            content: [
                CLIMessage.ContentBlock(
                    type: .text,
                    text: trimmed,
                    toolUseId: nil,
                    toolName: nil,
                    toolInput: nil,
                    uuid: nil,
                    parentUUID: nil
                )
            ],
            timestamp: Date(),
            toolUse: nil,
            rawMessageId: messageId,
            rawSeq: nil
        )
        appendMessageIfNeeded(statusMessage)
    }

    func allowPermission(_ permissionId: String, forSession: Bool = false) async {
        let resolvedPermissionId = resolvePermissionActionTargetID(permissionId)
        guard !permissionActionInFlight.contains(resolvedPermissionId) else { return }
        permissionActionInFlight.insert(resolvedPermissionId)
        defer { permissionActionInFlight.remove(resolvedPermissionId) }

        do {
            if forSession {
                try await client.sessionAllow(
                    sessionId: session.id,
                    permissionId: resolvedPermissionId,
                    allowedTools: [],
                    decision: "approved_for_session",
                    timeout: 20
                )
            } else {
                try await client.sessionAllow(
                    sessionId: session.id,
                    permissionId: resolvedPermissionId,
                    decision: "approved",
                    timeout: 20
                )
            }
            applyLocalPermissionDecision(
                permissionId: resolvedPermissionId,
                status: .approved,
                decision: forSession ? "approved_for_session" : "approved"
            )
            await syncMessagesFromRemote(forceFull: false)
        } catch {
            errorMessage = "权限确认失败: \(error.localizedDescription)"
            showError = true
        }
    }

    func denyPermission(_ permissionId: String, abort: Bool = false) async {
        let resolvedPermissionId = resolvePermissionActionTargetID(permissionId)
        guard !permissionActionInFlight.contains(resolvedPermissionId) else { return }
        permissionActionInFlight.insert(resolvedPermissionId)
        defer { permissionActionInFlight.remove(resolvedPermissionId) }

        do {
            try await client.sessionDeny(
                sessionId: session.id,
                permissionId: resolvedPermissionId,
                decision: abort ? "abort" : "denied",
                timeout: 20
            )
            applyLocalPermissionDecision(
                permissionId: resolvedPermissionId,
                status: abort ? .canceled : .denied,
                decision: abort ? "abort" : "denied"
            )
            await syncMessagesFromRemote(forceFull: false)
        } catch {
            errorMessage = "权限拒绝失败: \(error.localizedDescription)"
            showError = true
        }
    }

    // MARK: - Debug Replay (removable)

    func resetLocalCacheAndReplayFromRemote() async throws {
        guard !isSyncingRemoteMessages else {
            throw ReplayRefreshError.syncInProgress
        }
        guard let contextGoSessionId = resolvedContextGoSessionId else {
            throw ReplayRefreshError.invalidSession
        }

        persistFlushTask?.cancel()
        persistFlushTask = nil
        pendingPersistSnapshotsById.removeAll()

        remoteSessionMissing = false
        hasSyncedAgentStateFromRemote = false
        localTurnPending = false
        localLoadedTailCount = 0
        canLoadOlderLocalMessages = false
        lastSyncedSeq = 0
        knownToolNames.removeAll()
        messages = []
        activeTodoSnapshot = nil
        runtimeStateTitle = nil
        refreshRuntimeStateTitle()

        try await sessionRepository.clearMessageCache(sessionId: contextGoSessionId, notifyCloud: false)
        await ensureLocalSessionExists()
        await syncMessagesFromRemote(forceFull: true)

        if remoteSessionMissing {
            throw ReplayRefreshError.remoteSessionNotFound
        }
    }

    // MARK: - Voice Input (iOS Platform Capability)

    private func setupVoiceInput() {
        voiceManager.$isRecording
            .sink { [weak self] value in self?.isHoldingSpeakButton = value }
            .store(in: &cancellables)

        voiceManager.$recordingDuration
            .sink { [weak self] value in self?.recordingDuration = value }
            .store(in: &cancellables)

        voiceManager.$isRecognizing
            .sink { [weak self] value in self?.isRecognizing = value }
            .store(in: &cancellables)

        voiceManager.onTranscriptionComplete = { [weak self] transcript in
            guard let self = self else { return }
            self.inputText = transcript
            self.sendMessage()
        }
    }

    func startHoldToSpeakRecording() {
        Task { await voiceManager.startRecording() }
    }

    func finishHoldToSpeakRecording() async {
        await voiceManager.stopRecordingAndTranscribe()
    }

    func cancelHoldToSpeakRecording() {
        voiceManager.cancelRecording()
    }

    private var contextGoLinkedDefaultsKey: String {
        "cli.contextgo.linked.\(client.ownerAgentId)"
    }

    private var contextGoSpacesDefaultsKey: String {
        "cli.contextgo.spaces.\(client.ownerAgentId)"
    }

    private func resolveContextGoLinked(override: Bool?) -> Bool {
        if let override {
            return override
        }
        if UserDefaults.standard.object(forKey: contextGoLinkedDefaultsKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: contextGoLinkedDefaultsKey)
    }

    private func resolveContextGoSpaceIds(linked: Bool, override: [String]?) -> [String] {
        guard linked else { return [] }
        let rawIds = override ?? UserDefaults.standard.stringArray(forKey: contextGoSpacesDefaultsKey) ?? []
        var deduped: [String] = []
        var seen = Set<String>()
        for rawId in rawIds {
            let trimmed = rawId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            deduped.append(trimmed)
        }
        return deduped
    }

    private var resolvedContextGoSessionId: String? {
        session.id
    }

    private enum ReplayRefreshError: LocalizedError {
        case syncInProgress
        case invalidSession
        case remoteSessionNotFound

        var errorDescription: String? {
            switch self {
            case .syncInProgress:
                return "当前正在同步消息，请稍后重试"
            case .invalidSession:
                return "当前会话无效"
            case .remoteSessionNotFound:
                return "服务端未找到该会话"
            }
        }
    }

    private var bridgeProvider: CoreSessionEventProvider {
        let runtimeProvider = session.metadata?.runtime?.provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let flavor = session.metadata?.flavor?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoreSessionEventProvider.fromRuntimeValue(runtimeProvider ?? flavor)
    }

    private var isCodexSession: Bool {
        bridgeProvider == .codex
    }

    private var supportsRuntimeStatusSlot: Bool {
        switch bridgeProvider {
        case .codex, .opencode:
            return true
        default:
            return false
        }
    }

    private func resolveCoreSessionEventRoute() async -> (sessionId: String, sessionKey: String, attemptId: String)? {
        guard let contextGoSessionId = resolvedContextGoSessionId else { return nil }

        var resolvedSessionKey = "cli:\(session.id)"
        if let contextSession = try? await sessionRepository.getSession(id: contextGoSessionId),
           let metadata = contextSession.channelMetadataDict,
           let sessionKey = metadata["sessionKey"] as? String {
            let trimmedSessionKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedSessionKey.isEmpty {
                resolvedSessionKey = trimmedSessionKey
            }
        }

        return (
            sessionId: contextGoSessionId,
            sessionKey: resolvedSessionKey,
            attemptId: "ios-attempt-\(contextGoSessionId)"
        )
    }

    private func reportInstructionEventToCore(
        text: String,
        localId: String,
        contextGoLinked: Bool,
        contextGoSpaceIds: [String],
        skillAutoLoad: Bool,
        skillIntent: String?,
        skillSpaceIds: [String],
        skillPinnedUris: [String]
    ) async {
        guard let route = await resolveCoreSessionEventRoute() else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        var messageMetadata: [String: Any] = [
            "sentFrom": "ios",
            "localId": localId,
            "contextGoLinked": contextGoLinked,
            "skillAutoLoad": skillAutoLoad
        ]
        if !contextGoSpaceIds.isEmpty {
            messageMetadata["spaceIds"] = contextGoSpaceIds
        }
        if !skillSpaceIds.isEmpty {
            messageMetadata["skillSpaceIds"] = skillSpaceIds
        }
        if !skillPinnedUris.isEmpty {
            messageMetadata["skillPinnedUris"] = skillPinnedUris
        }
        if let skillIntent, !skillIntent.isEmpty {
            messageMetadata["skillIntent"] = skillIntent
        }

        let messagePayload: [String: Any] = [
            "id": localId,
            "sessionId": route.sessionId,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "role": "user",
            "content": text,
            "metadata": messageMetadata
        ]

        var payload: [String: AnyCodable] = [
            "message": AnyCodable(messagePayload)
        ]
        if contextGoLinked, let firstSpaceId = contextGoSpaceIds.first, !firstSpaceId.isEmpty {
            payload["spaceId"] = AnyCodable(firstSpaceId)
            payload["spaceIds"] = AnyCodable(contextGoSpaceIds)
        }

        let now = ISO8601DateFormatter().string(from: Date())
        let event = CgoEventInput(
            eventId: nil,
            scope: .session(
                sessionId: route.sessionId,
                sessionKey: route.sessionKey,
                attemptId: route.attemptId
            ),
            provider: bridgeProvider,
            source: .iosCLI,
            type: .messageAppended,
            timestamp: now,
            payload: payload
        )

        do {
            _ = try await coreClient.appendEvent(event: event)
        } catch {
            print("[CLISessionViewModel] appendEvent(message.appended) failed for \(route.sessionId): \(error)")
        }
    }

    private func reportAbortEventToCore(reason: String = "user_cancelled") async {
        guard let route = await resolveCoreSessionEventRoute() else { return }

        let nowDate = Date()
        let now = ISO8601DateFormatter().string(from: nowDate)
        let turnId = messages
            .reversed()
            .compactMap { $0.runId?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty }) ?? UUID().uuidString

        let payload: [String: AnyCodable] = [
            "turn": AnyCodable([
                "id": turnId,
                "abortedAt": now
            ]),
            "result": AnyCodable([
                "status": "aborted",
                "reason": reason
            ])
        ]

        let event = CgoEventInput(
            eventId: nil,
            scope: .session(
                sessionId: route.sessionId,
                sessionKey: route.sessionKey,
                attemptId: route.attemptId
            ),
            provider: bridgeProvider,
            source: .iosCLI,
            type: .turnAborted,
            timestamp: now,
            payload: payload
        )

        do {
            _ = try await coreClient.appendEvent(event: event)
        } catch {
            print("[CLISessionViewModel] appendEvent(turn.aborted) failed for \(route.sessionId): \(error)")
        }
    }

    private func ensureLocalSessionExists() async {
        guard let contextGoSessionId = resolvedContextGoSessionId else { return }

        do {
            if let _ = try await sessionRepository.getSession(id: contextGoSessionId) {
                return
            }

            var channelMetadata: [String: Any] = [
                "cliSessionId": session.id,
                "sessionUri": SessionStorageLayout.sessionResourceURI(agentId: client.ownerAgentId, sessionId: session.id)
            ]

            if let metadata = session.metadata {
                channelMetadata["path"] = metadata.path
                channelMetadata["pathBasename"] = metadata.pathBasename
                channelMetadata["machineId"] = metadata.machineId
                channelMetadata["host"] = metadata.host
                channelMetadata["hostPid"] = metadata.hostPid as Any
                channelMetadata["flavor"] = metadata.flavor as Any
                channelMetadata["homeDir"] = metadata.homeDir
                channelMetadata["claudeSessionId"] = metadata.claudeSessionId as Any
                channelMetadata["codexSessionId"] = metadata.codexSessionId as Any
                channelMetadata["opencodeSessionId"] = metadata.opencodeSessionId as Any
                channelMetadata["geminiSessionId"] = metadata.geminiSessionId as Any
                channelMetadata["customTitle"] = metadata.customTitle as Any
            }

            var contextSession = ContextGoSession(
                id: contextGoSessionId,
                agentId: client.ownerAgentId,
                title: session.displayName,
                preview: messages.last?.displayText ?? "",
                tags: ["cli"],
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                lastMessageTime: session.updatedAt,
                isActive: session.active,
                isPinned: false,
                isArchived: false,
                channelMetadata: nil,
                messagesCachePath: SessionStorageLayout.messagesRelativePath(agentId: client.ownerAgentId, sessionId: contextGoSessionId),
                syncStatus: .synced,
                lastSyncAt: Date()
            )
            contextSession.setChannelMetadata(channelMetadata)
            try await sessionRepository.createSession(contextSession, notifyCloud: false)
        } catch {
            print("[CLISessionViewModel] Failed to ensure local session: \(error)")
        }
    }

    private func persistMessage(_ message: CLIMessage) {
        persistMessages([message])
    }

    private func persistMessages(_ messages: [CLIMessage]) {
        guard !messages.isEmpty else { return }
        guard let contextGoSessionId = resolvedContextGoSessionId else { return }

        for message in messages where shouldPersistMessageSnapshot(message) {
            pendingPersistSnapshotsById[message.id] = message
        }
        guard !pendingPersistSnapshotsById.isEmpty else { return }

        schedulePersistFlush(sessionId: contextGoSessionId)
    }

    private func schedulePersistFlush(sessionId: String) {
        guard persistFlushTask == nil else { return }

        persistFlushTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: persistDebounceNanoseconds)
            await self.flushPendingPersistMessages(sessionId: sessionId)
        }
    }

    @MainActor
    private func flushPendingPersistMessages(sessionId: String) async {
        defer { persistFlushTask = nil }

        guard !pendingPersistSnapshotsById.isEmpty else { return }
        let persistable = pendingPersistSnapshotsById.values
            .sorted(by: { $0.timestamp < $1.timestamp })
        pendingPersistSnapshotsById.removeAll()

        do {
            for message in persistable {
                let stored = buildStoredMessage(message, sessionId: sessionId)
                try await sessionRepository.cacheMessage(stored, to: sessionId)
            }
        } catch {
            print("[CLISessionViewModel] Failed to persist message in repository: \(error)")
        }

        if !pendingPersistSnapshotsById.isEmpty {
            schedulePersistFlush(sessionId: sessionId)
        }
    }

    private func shouldPersistMessageSnapshot(_ message: CLIMessage) -> Bool {
        if message.role == .user {
            return true
        }

        let hasRenderableText = message.content.contains { block in
            switch block.type {
            case .text, .thinking, .event:
                guard let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else { return false }
                return !Self.isPlaceholderToolToken(text)
            case .toolUse, .toolResult:
                return false
            }
        }
        if hasRenderableText {
            return true
        }

        guard let tools = message.toolUse, !tools.isEmpty else {
            return false
        }

        for tool in tools {
            if tool.permission?.status == .pending {
                return true
            }
            if tool.status == .success || tool.status == .error {
                return true
            }
        }

        return false
    }

    private func buildStoredMessage(_ message: CLIMessage, sessionId: String) -> SessionMessage {
        let sanitizedMessage = Self.sanitizeMessagePayload(
            message,
            agentId: client.ownerAgentId,
            sessionId: sessionId,
            mode: .persist,
            codexOptimizationsEnabled: isCodexSession
        )
        let metadata = buildMetadata(from: sanitizedMessage)
        return SessionMessage(
            id: sanitizedMessage.id,
            sessionId: sessionId,
            timestamp: sanitizedMessage.timestamp,
            role: roleForStorage(sanitizedMessage.role),
            content: sanitizedMessage.displayText,
            toolCalls: sanitizedMessage.toolUse?.map { ToolCall(id: $0.id, name: $0.name, input: $0.input) },
            toolResults: sanitizedMessage.toolUse?.compactMap { tool in
                guard tool.output != nil || tool.status == .error else { return nil }
                return ToolResult(toolCallId: tool.id, output: tool.output, error: tool.status == .error ? "error" : nil)
            },
            metadata: metadata
        )
    }

    private func buildMetadata(from message: CLIMessage) -> [String: AnyCodable] {
        var metadata: [String: AnyCodable] = [:]

        if let data = try? JSONEncoder().encode(message.content),
           let json = String(data: data, encoding: .utf8) {
            metadata["cliContent"] = AnyCodable(json)
        }

        if let tools = message.toolUse,
           let data = try? JSONEncoder().encode(tools),
           let json = String(data: data, encoding: .utf8) {
            metadata["cliToolUse"] = AnyCodable(json)
        }

        metadata["rawMessageId"] = AnyCodable(message.rawMessageId ?? message.id)

        if let rawSeq = message.rawSeq {
            metadata["cliSeq"] = AnyCodable(rawSeq)
        }
        if let runId = message.runId, !runId.isEmpty {
            metadata["cliRunId"] = AnyCodable(runId)
        }
        if let parentRunId = message.parentRunId, !parentRunId.isEmpty {
            metadata["cliParentRunId"] = AnyCodable(parentRunId)
        }
        if message.isSidechain {
            metadata["cliIsSidechain"] = AnyCodable(true)
        }
        if let selectedSkillName = message.selectedSkillName,
           !selectedSkillName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["skillSelectedName"] = AnyCodable(selectedSkillName)
        }
        if let selectedSkillUri = message.selectedSkillUri,
           !selectedSkillUri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            metadata["skillSelectedUri"] = AnyCodable(selectedSkillUri)
        }

        return metadata
    }

    private func roleForStorage(_ role: CLIMessage.Role) -> MessageRole {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        }
    }

    // MARK: - Runtime title extraction

    private func refreshRuntimeStateTitle() {
        guard hasActiveRun, supportsRuntimeStatusSlot else {
            runtimeStateTitle = nil
            return
        }

        if isAborting {
            runtimeStateTitle = "Stopping..."
            return
        }

        if let dynamic = latestDynamicRuntimeTitle(), !dynamic.isEmpty {
            runtimeStateTitle = dynamic
            return
        }

        runtimeStateTitle = "Working"
    }

    private func latestDynamicRuntimeTitle() -> String? {
        guard supportsRuntimeStatusSlot else { return nil }

        for message in messages.reversed() {
            if let tools = message.toolUse {
                for tool in tools.reversed() {
                    if isReasoningToolName(tool.name) {
                        if let title = normalizeRuntimeTitleCandidate(extractTitleFromReasoningPayload(tool.input)),
                           !title.isEmpty {
                            return title
                        }
                        if let title = normalizeRuntimeTitleCandidate(extractTitleFromReasoningPayload(tool.output)),
                           !title.isEmpty {
                            return title
                        }
                        if let description = normalizeRuntimeTitleCandidate(tool.description),
                           !description.isEmpty {
                            return description
                        }
                    }
                }
            }

            for block in message.content.reversed() {
                guard block.type == .thinking else { continue }
                guard let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { continue }
                let line = text
                    .split(whereSeparator: \.isNewline)
                    .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty } ?? text
                if let normalized = normalizeRuntimeTitleCandidate(line),
                   !normalized.isEmpty {
                    return normalized
                }
            }
        }
        return nil
    }

    private func isReasoningToolName(_ name: String) -> Bool {
        CLIToolSemantics.isReasoningName(name)
    }

    private func extractTitleFromReasoningPayload(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }

        let candidateKeys = ["text", "delta", "summary", "title", "reasoningTitle", "phase", "step", "label"]

        if let dict = json as? [String: Any] {
            for key in candidateKeys {
                if let value = dict[key] {
                    let text = stringifyJSONValue(value)
                    if !text.isEmpty {
                        return text
                    }
                }
            }
        }

        return nil
    }

    private func stringifyJSONValue(_ value: Any) -> String {
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return ""
    }

    private func normalizeRuntimeTitleCandidate(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.hasPrefix("**"), text.hasSuffix("**"), text.count > 4 {
            text = String(text.dropFirst(2).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.hasPrefix("`"), text.hasSuffix("`"), text.count > 2 {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !text.isEmpty else { return nil }
        guard !looksLikeProtocolMarkerLabel(text) else { return nil }

        let hasMeaningfulCharacters = text.contains { $0.isLetter || $0.isNumber }
        guard hasMeaningfulCharacters else { return nil }

        return text.count > 56 ? String(text.prefix(56)) + "…" : text
    }

    private func looksLikeProtocolMarkerLabel(_ raw: String) -> Bool {
        let canonical = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "/", with: ".")
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: #"\.+"#, with: ".", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        guard !canonical.isEmpty else { return true }
        let exactMarkers: Set<String> = [
            "agent.reason",
            "agent.reasoning",
            "agent.reasoning.delta",
            "agent.reasoning.section.break",
            "event",
            "status"
        ]
        if exactMarkers.contains(canonical) {
            return true
        }

        return canonical.hasPrefix("agent.reasoning.")
            || canonical.hasPrefix("codex.event.agent.reasoning.")
            || canonical.hasPrefix("event.agent.reasoning.")
    }

    nonisolated private static func decodeCLIMessageRaw(
        _ stored: SessionMessage,
        agentId: String? = nil,
        sessionId: String? = nil,
        codexOptimizationsEnabled: Bool = false
    ) -> CLIMessage? {
        let decodedRole: CLIMessage.Role
        switch stored.role {
        case .user: decodedRole = .user
        case .assistant: decodedRole = .assistant
        case .system, .tool: decodedRole = .system
        }

        var content: [CLIMessage.ContentBlock]? = nil
        if let encoded = stored.metadata?["cliContent"]?.value as? String,
           let data = encoded.data(using: .utf8),
           let blocks = try? JSONDecoder().decode([CLIMessage.ContentBlock].self, from: data) {
            content = blocks
        }

        var toolUse: [CLIMessage.ToolUse]? = nil
        if let encodedTools = stored.metadata?["cliToolUse"]?.value as? String,
           let data = encodedTools.data(using: .utf8),
           let tools = try? JSONDecoder().decode([CLIMessage.ToolUse].self, from: data) {
            toolUse = tools
        }
        if toolUse == nil || toolUse?.isEmpty == true {
            toolUse = rebuildLegacyToolUse(from: stored)
        }
        if (toolUse == nil || toolUse?.isEmpty == true),
           let blocks = content {
            toolUse = rebuildToolUseFromContentBlocks(blocks)
        }

        if content == nil {
            let fallbackText = sanitizeInlineText(stored.content)
            if decodedRole == .assistant,
               let toolUse,
               !toolUse.isEmpty,
               !shouldKeepLegacyAssistantText(fallbackText) {
                content = []
            } else if decodedRole == .assistant,
                      !shouldKeepLegacyAssistantText(fallbackText) {
                content = []
            } else if !fallbackText.isEmpty {
                content = [
                    CLIMessage.ContentBlock(
                        type: .text,
                        text: fallbackText,
                        toolUseId: nil,
                        toolName: nil,
                        toolInput: nil,
                        uuid: nil,
                        parentUUID: nil
                    )
                ]
            } else {
                content = []
            }
        }

        let rawSeq: Int? = {
            if let intValue = stored.metadata?["cliSeq"]?.value as? Int {
                return intValue
            }
            if let number = stored.metadata?["cliSeq"]?.value as? NSNumber {
                return number.intValue
            }
            if let string = stored.metadata?["cliSeq"]?.value as? String {
                return Int(string)
            }
            return nil
        }()

        let rawMessageId: String? = {
            if let value = stored.metadata?["rawMessageId"]?.value as? String, !value.isEmpty {
                return value
            }
            return nil
        }()

        let runId: String? = {
            if let value = stored.metadata?["cliRunId"]?.value as? String, !value.isEmpty {
                return value
            }
            return nil
        }()

        let parentRunId: String? = {
            if let value = stored.metadata?["cliParentRunId"]?.value as? String, !value.isEmpty {
                return value
            }
            return nil
        }()

        let isSidechain: Bool = {
            if let value = stored.metadata?["cliIsSidechain"]?.value as? Bool {
                return value
            }
            if let value = stored.metadata?["cliIsSidechain"]?.value as? NSNumber {
                return value.boolValue
            }
            if let value = stored.metadata?["cliIsSidechain"]?.value as? String {
                return ["true", "1", "yes"].contains(value.lowercased())
            }
            return false
        }()

        let selectedSkillName = firstNonEmptyStringFromAny([
            stored.metadata?["skillSelectedName"]?.value,
            stored.metadata?["selectedSkillName"]?.value,
            stored.metadata?["skillIntent"]?.value
        ])
        let selectedSkillUri = firstNonEmptyStringFromAny([
            stored.metadata?["skillSelectedUri"]?.value,
            stored.metadata?["selectedSkillUri"]?.value
        ])

        let message = CLIMessage(
            id: stored.id,
            role: decodedRole,
            content: content ?? [],
            timestamp: stored.timestamp,
            toolUse: toolUse,
            rawMessageId: rawMessageId ?? stored.id,
            rawSeq: rawSeq,
            runId: runId,
            parentRunId: parentRunId,
            isSidechain: isSidechain,
            selectedSkillName: selectedSkillName,
            selectedSkillUri: selectedSkillUri
        )
        return sanitizeMessagePayload(
            message,
            agentId: agentId,
            sessionId: sessionId,
            mode: .display,
            codexOptimizationsEnabled: codexOptimizationsEnabled
        )
    }

    nonisolated private static func rebuildLegacyToolUse(from stored: SessionMessage) -> [CLIMessage.ToolUse]? {
        var map: [String: CLIMessage.ToolUse] = [:]

        for call in stored.toolCalls ?? [] {
            map[call.id] = CLIMessage.ToolUse(
                id: call.id,
                name: call.name,
                input: call.input,
                output: nil,
                status: .running,
                executionTime: nil,
                description: nil,
                permission: nil
            )
        }

        for result in stored.toolResults ?? [] {
            var existing = map[result.toolCallId] ?? CLIMessage.ToolUse(
                id: result.toolCallId,
                name: "tool",
                input: nil,
                output: nil,
                status: .pending,
                executionTime: nil,
                description: nil,
                permission: nil
            )

            if let output = result.output?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                existing.output = output
            }

            let hasError = !(result.error?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
            if hasError {
                existing.status = .error
            } else if let output = existing.output,
                      !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                existing.status = .success
            } else if existing.status == .pending {
                existing.status = .success
            }

            map[result.toolCallId] = existing
        }

        if map.isEmpty {
            return nil
        }
        return map.values.sorted { $0.id < $1.id }
    }

    nonisolated private static func rebuildToolUseFromContentBlocks(
        _ blocks: [CLIMessage.ContentBlock]
    ) -> [CLIMessage.ToolUse]? {
        var map: [String: CLIMessage.ToolUse] = [:]
        var orderedIds: [String] = []

        for block in blocks {
            switch block.type {
            case .toolUse:
                guard let id = block.toolUseId, !id.isEmpty else { continue }
                if map[id] == nil {
                    orderedIds.append(id)
                }
                var tool = map[id] ?? CLIMessage.ToolUse(
                    id: id,
                    name: block.toolName ?? "tool",
                    input: nil,
                    output: nil,
                    status: .pending,
                    executionTime: nil,
                    description: nil,
                    permission: nil
                )

                if tool.name == "tool",
                   let name = block.toolName,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tool.name = name
                }

                if tool.input == nil,
                   let serializedInput = serializeLegacyToolInput(block.toolInput),
                   !serializedInput.isEmpty {
                    tool.input = serializedInput
                }

                if tool.status == .pending {
                    tool.status = .running
                }

                map[id] = tool

            case .toolResult:
                guard let id = block.toolUseId, !id.isEmpty else { continue }
                if map[id] == nil {
                    orderedIds.append(id)
                }
                var tool = map[id] ?? CLIMessage.ToolUse(
                    id: id,
                    name: block.toolName ?? "tool",
                    input: nil,
                    output: nil,
                    status: .pending,
                    executionTime: nil,
                    description: nil,
                    permission: nil
                )

                if tool.name == "tool",
                   let name = block.toolName,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    tool.name = name
                }

                if let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    tool.output = text
                    let lowered = text.lowercased()
                    if lowered.contains("\"iserror\":true")
                        || lowered.contains("\"is_error\":true")
                        || lowered.contains("\"status\":\"failed\"")
                        || lowered.contains("\"status\":\"error\"")
                        || lowered.contains("\"status\":\"cancelled\"")
                        || lowered.contains("\"status\":\"canceled\"")
                        || lowered.contains("\"error\"") {
                        tool.status = .error
                    } else {
                        tool.status = .success
                    }
                } else if tool.status == .pending {
                    tool.status = .success
                }

                map[id] = tool

            case .text, .thinking, .event:
                continue
            }
        }

        guard !map.isEmpty else { return nil }

        return orderedIds.compactMap { map[$0] }
    }

    nonisolated private static func serializeLegacyToolInput(_ input: [String: String]?) -> String? {
        guard let input, !input.isEmpty else { return nil }
        if let raw = input["_raw"]?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            return raw
        }

        let dict = Dictionary(uniqueKeysWithValues: input.map { ($0.key, $0.value) })
        if JSONSerialization.isValidJSONObject(dict),
           let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
           let text = String(data: data, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        let flattened = input
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return flattened.isEmpty ? nil : flattened
    }

    nonisolated private static func shouldKeepLegacyAssistantText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count <= 160 {
            return true
        }

        let lowered = trimmed.lowercased()
        if isPlaceholderToolToken(trimmed) || isLikelyPlanningScratchText(trimmed) {
            return false
        }
        if lowered.contains("tool result (id:") ||
            lowered.contains("[agent usage reminder]") ||
            lowered.contains("<path>") ||
            lowered.contains("</content>") ||
            lowered.contains("\"status\":\"completed\"") ||
            lowered.contains("\"status\": \"completed\"") ||
            lowered.contains("\"status\":\"success\"") ||
            lowered.contains("\"status\": \"success\"") {
            return false
        }

        return true
    }

    nonisolated private static func stripPlaceholderToolLines(from raw: String) -> String {
        let lines = raw
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        let filtered = lines.filter { line in
            !isPlaceholderToolToken(line)
        }

        guard !filtered.isEmpty else { return "" }
        return filtered.joined(separator: "\n")
    }

    nonisolated private static func isPlaceholderToolToken(_ text: String) -> Bool {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return false }

        let compact = normalized.replacingOccurrences(of: " ", with: "")
        let directTokens: Set<String> = [
            "[tool_use]",
            "[tool-result]",
            "[tool_result]",
            "[tooluse]",
            "[toolresult]",
            "tool_use",
            "tool_result",
            "tooluse",
            "toolresult"
        ]
        if directTokens.contains(compact) {
            return true
        }

        let wrapped = compact.replacingOccurrences(of: "`", with: "")
        return wrapped == "[tool_use]" || wrapped == "[tool_result]"
    }

    nonisolated private static func isLikelyPlanningScratchText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= 360 else { return false }

        let compact = trimmed.replacingOccurrences(of: "**", with: "")
        let lines = compact
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 3 else { return false }

        let first = lines[0].lowercased()
        guard first.contains("plan") else { return false }

        let shortLikeCount = lines.dropFirst().filter { raw in
            let normalized = raw.replacingOccurrences(
                of: #"^[\-\*\u{2022}\d\.\)\s]+"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return false }
            let words = normalized.split(whereSeparator: \.isWhitespace)
            return normalized.count <= 28 && words.count <= 3
        }.count

        return shortLikeCount >= max(2, Int(Double(lines.count - 1) * 0.5))
    }
}

private final class CLIPermissionNotificationCenter {
    static let shared = CLIPermissionNotificationCenter()

    private var didRequestAuthorization = false

    private init() {}

    func notifyPermissionRequired(
        sessionId: String,
        permissionId: String,
        toolName: String,
        reason: String?
    ) {
        let center = UNUserNotificationCenter.current()

        if !didRequestAuthorization {
            didRequestAuthorization = true
            center.requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
        }

        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral else {
                return
            }

            let normalizedToolName = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayToolName = normalizedToolName.isEmpty ? "tool" : normalizedToolName
            let normalizedReason = reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let content = UNMutableNotificationContent()
            content.title = "ContextGo permission required"
            if normalizedReason.isEmpty {
                content.body = "Codex needs approval for \(displayToolName)."
            } else {
                content.body = "Codex needs approval for \(displayToolName): \(normalizedReason)"
            }
            content.sound = .default
            content.userInfo = [
                "sessionId": sessionId,
                "permissionId": permissionId,
                "provider": "codex"
            ]

            let identifier = "contextgo.permission.\(sessionId).\(permissionId)"
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
            center.add(request)
        }
    }
}
