//
//  OpenClawClient.swift
//  contextgo
//
//  IronClaw native API client with compatibility shims for existing clawhome UI.
//

import Foundation

private extension JSONDecoder {
    static let snakeCase: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}

import Combine
import UIKit

@MainActor
class OpenClawClient: ObservableObject {
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var presenceInfo: ConnectResponse.HelloPayload.PresenceInfo?

    var activeRunQueue: [String] { runQueue }
    var hasActiveRuns: Bool { !runQueue.isEmpty }

    private let baseURL: URL
    private let session = URLSession(configuration: .default)
    private let coreConfig = CoreConfig.shared

    private var runQueue: [String] = []
    private var bufferedMessages: [String: BufferedMessage] = [:]
    private var threadIDsBySessionKey: [String: String] = [:]
    private let maxBufferAge: TimeInterval = 3600
    private var currentResponseTask: Task<Void, Never>?

    struct ChatStateEvent {
        let runId: String
        let sessionKey: String
        let state: String
        let text: String?
        let thinking: String?
        let stopReason: String?
        let errorMessage: String?
    }

    struct CompactionEvent {
        let runId: String
        let phase: String
        let messageCount: Int?
    }

    var onAgentStreamDelta: ((String) -> Void)?
    var onAgentThinkingDelta: ((String) -> Void)?
    var onAgentComplete: (() -> Void)?
    var onAgentError: ((String) -> Void)?
    var onRunAccepted: ((String) -> Void)?
    var onChatStateEvent: ((ChatStateEvent) -> Void)?
    var onToolExecutionStart: ((String, String, String, String?) -> Void)?
    var onToolExecutionUpdate: ((String, String, String) -> Void)?
    var onToolExecutionResult: ((String, String, String?, String?) -> Void)?
    var onLifecycleStart: ((String) -> Void)?
    var onLifecycleEnd: ((String) -> Void)?
    var onLifecycleError: ((String, String) -> Void)?
    var onMemoryCompaction: ((Int) -> Void)?
    var onCompactionEvent: ((CompactionEvent) -> Void)?
    var onRunQueueChanged: ((Bool) -> Void)?
    var onCronEvent: ((CronEvent) -> Void)?
    var onOtherChannelActivity: ((Set<String>, Bool) -> Void)?

    struct BufferedMessage: Codable {
        let sessionKey: String
        let runId: String
        var deltas: [String]
        let timestamp: Date
        var isComplete: Bool
        var error: String?

        var fullText: String { deltas.joined() }
    }

    nonisolated init(url: URL) {
        if let normalized = Self.normalizedHTTPURL(from: url) {
            self.baseURL = normalized
        } else {
            self.baseURL = URL(string: "http://127.0.0.1:8642")!
        }
    }

    nonisolated private static func normalizedHTTPURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.scheme == "ws" {
            components.scheme = "http"
        } else if components.scheme == "wss" {
            components.scheme = "https"
        }
        if components.path.isEmpty {
            components.path = ""
        }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func endpoint(_ path: String) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.path = path
        return components.url!
    }

    private func makeRequest(
        path: String,
        method: String,
        jsonBody: Any? = nil,
        extraHeaders: [String: String] = [:]
    ) throws -> URLRequest {
        let url = endpoint(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 60
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let token = coreConfig.jwtToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if let jsonBody {
            request.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        return request
    }

    private func validate(_ response: URLResponse, data: Data? = nil, endpoint: String? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenClawError.requestFailed("Invalid IronClaw response")
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 404, endpoint == "/tools/invoke" {
                throw OpenClawError.requestFailed("当前 IronClaw 部署未启用工具接口（/tools/invoke），该功能不可用")
            }
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw OpenClawError.requestFailed(message)
            }
            throw OpenClawError.requestFailed("IronClaw request failed (HTTP \(http.statusCode))")
        }
    }

    func connect() {
        guard connectionState != .connecting else { return }
        connectionState = .connecting

        Task {
            do {
                _ = try await fetchModels()
                isConnected = true
                connectionState = .connected
                presenceInfo = ConnectResponse.HelloPayload.PresenceInfo(online: true, model: "IronClaw")
            } catch {
                isConnected = false
                connectionState = .error(error.localizedDescription)
            }
        }
    }

    func disconnect() {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        isConnected = false
        presenceInfo = nil
        connectionState = .disconnected
        runQueue.removeAll()
        notifyRunQueueChanged()
    }

    func updateURL(_ newURL: URL) {
        // Compatibility no-op: callers recreate clients via ConnectionManager.
        _ = newURL
        disconnect()
        connect()
    }

    func sendMessage(
        _ message: String,
        thinking: String? = nil,
        sessionKey: String? = nil,
        attachments: [OpenClawAttachment] = []
    ) async throws -> String {
        guard isConnected else { throw OpenClawError.notConnected }

        let resolvedSessionKey = sessionKey ?? "agent:main:operator:default"
        let runId = "hermes-run-\(UUID().uuidString)"
        runQueue.append(runId)
        notifyRunQueueChanged()
        onRunAccepted?(runId)
        onLifecycleStart?(runId)
        if let thinking, !thinking.isEmpty {
            onAgentThinkingDelta?(thinking)
        }

        currentResponseTask?.cancel()
        currentResponseTask = Task { [weak self] in
            guard let self else { return }
            await self.sendThreadMessage(runId: runId, sessionKey: resolvedSessionKey, message: message, attachments: attachments)
        }

        return runId
    }

    private func sendThreadMessage(runId: String, sessionKey: String, message: String, attachments: [OpenClawAttachment]) async {
        do {
            let threadId = try await resolveThreadID(for: sessionKey)
            onChatStateEvent?(ChatStateEvent(runId: runId, sessionKey: sessionKey, state: "accepted", text: nil, thinking: nil, stopReason: nil, errorMessage: nil))

            let baselineHistory = try await fetchThreadHistory(threadId: threadId)
            let baselineTurnCount = baselineHistory.turns.count
            let content = composeThreadMessageContent(message: message, attachments: attachments)

            try await postThreadMessage(content: content, threadId: threadId)
            let poll = try await waitForThreadTurn(threadId: threadId, afterTurnCount: baselineTurnCount)
            let responseText = (poll.latestTurn.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if !responseText.isEmpty {
                bufferReplacement(text: responseText, sessionKey: sessionKey, runId: runId)
                onAgentStreamDelta?(responseText)
            }

            markBufferedComplete(sessionKey: sessionKey)
            onChatStateEvent?(ChatStateEvent(runId: runId, sessionKey: sessionKey, state: "final", text: responseText, thinking: nil, stopReason: nil, errorMessage: nil))
            onLifecycleEnd?(runId)
            onAgentComplete?()
            removeRun(runId)
        } catch is CancellationError {
            removeRun(runId)
        } catch {
            let message = error.localizedDescription
            markBufferedError(sessionKey: sessionKey, message: message)
            onChatStateEvent?(ChatStateEvent(runId: runId, sessionKey: sessionKey, state: "error", text: nil, thinking: nil, stopReason: nil, errorMessage: message))
            onLifecycleError?(runId, message)
            onAgentError?(message)
            removeRun(runId)
        }
    }

    private func composeThreadMessageContent(message: String, attachments: [OpenClawAttachment]) -> String {
        guard !attachments.isEmpty else { return message }
        let names = attachments.map(\.fileName).joined(separator: ", ")
        if message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "附件: \(names)"
        }
        return "\(message)\n\n附件: \(names)"
    }

    private func resolveThreadID(for sessionKey: String) async throws -> String {
        if let existing = threadIDsBySessionKey[sessionKey], !existing.isEmpty {
            return existing
        }
        if UUID(uuidString: sessionKey) != nil {
            threadIDsBySessionKey[sessionKey] = sessionKey
            return sessionKey
        }
        let created = try await createThread()
        threadIDsBySessionKey[sessionKey] = created.id
        return created.id
    }

    private func postThreadMessage(content: String, threadId: String) async throws {
        let request = try makeRequest(
            path: "/api/chat/send",
            method: "POST",
            jsonBody: [
                "content": content,
                "thread_id": threadId,
                "timezone": TimeZone.current.identifier,
            ]
        )
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
    }

    private func waitForThreadTurn(threadId: String, afterTurnCount: Int, timeout: TimeInterval = 45) async throws -> ThreadPollResult {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let history = try await fetchThreadHistory(threadId: threadId)
            if let latest = history.turns.last,
               history.turns.count > afterTurnCount,
               latest.isTerminal {
                return ThreadPollResult(history: history, latestTurn: latest)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        throw OpenClawError.timeout
    }

    private func fetchThreadHistory(threadId: String) async throws -> IronClawThreadHistoryResponse {
        let encoded = threadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? threadId
        let request = try makeRequest(path: "/api/chat/history?thread_id=\(encoded)", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder.snakeCase.decode(IronClawThreadHistoryResponse.self, from: data)
    }

    private func createThread() async throws -> IronClawThreadInfo {
        let request = try makeRequest(path: "/api/chat/thread/new", method: "POST")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder.snakeCase.decode(IronClawThreadInfo.self, from: data)
    }

    private func threadHistoryMessages(from history: IronClawThreadHistoryResponse) -> [ChatHistoryResponse.HistoryMessage] {
        history.turns.enumerated().flatMap { index, turn -> [ChatHistoryResponse.HistoryMessage] in
            let timestamp = Self.timestampMs(from: turn.startedAt)
            var items: [ChatHistoryResponse.HistoryMessage] = []
            let user = turn.userInput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !user.isEmpty {
                items.append(
                    ChatHistoryResponse.HistoryMessage(
                        id: "\(turn.turnNumber ?? index)-user",
                        timestamp: timestamp,
                        role: "user",
                        content: [.init(type: "text", text: user)],
                        toolUse: nil,
                        toolResult: nil
                    )
                )
            }
            let assistant = (turn.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !assistant.isEmpty {
                items.append(
                    ChatHistoryResponse.HistoryMessage(
                        id: "\(turn.turnNumber ?? index)-assistant",
                        timestamp: timestamp,
                        role: "assistant",
                        content: [.init(type: "text", text: assistant)],
                        toolUse: nil,
                        toolResult: nil
                    )
                )
            }
            return items
        }
    }

    private static func timestampMs(from iso8601: String?) -> Int {
        guard let iso8601,
              let date = ISO8601DateFormatter().date(from: iso8601) else {
            return Int(Date().timeIntervalSince1970 * 1000)
        }
        return Int(date.timeIntervalSince1970 * 1000)
    }

    private struct ThreadPollResult {
        let history: IronClawThreadHistoryResponse
        let latestTurn: IronClawThreadTurn
    }

    private struct IronClawThreadInfo: Decodable {
        let id: String
    }

    private struct IronClawThreadHistoryResponse: Decodable {
        let threadId: String
        let turns: [IronClawThreadTurn]
        let hasMore: Bool
    }

    private struct IronClawThreadTurn: Decodable {
        let turnNumber: Int?
        let userInput: String
        let response: String?
        let state: String
        let startedAt: String?

        var isTerminal: Bool {
            let normalized = state.lowercased()
            return normalized.contains("completed") || normalized.contains("failed") || normalized.contains("accepted")
        }
    }

    func abortChat(sessionKey: String? = nil, runId: String? = nil) async throws -> Int {
        currentResponseTask?.cancel()
        currentResponseTask = nil
        let resolvedRunId = runId ?? runQueue.first
        if let resolvedRunId {
            removeRun(resolvedRunId)
            onChatStateEvent?(ChatStateEvent(runId: resolvedRunId, sessionKey: sessionKey ?? "", state: "aborted", text: nil, thinking: nil, stopReason: "stopped", errorMessage: nil))
            onLifecycleError?(resolvedRunId, "stopped")
            onAgentComplete?()
            return 1
        }
        return 0
    }

    func abortOldestRun() async throws -> Int {
        try await abortChat(sessionKey: nil, runId: runQueue.first)
    }

    func checkHealth() async throws -> String {
        let candidatePaths = ["/api/gateway/status", "/health/detailed", "/health"]
        var lastError: Error?

        for path in candidatePaths {
            do {
                let request = try makeRequest(path: path, method: "GET")
                let (data, response) = try await session.data(for: request)
                try validate(response, data: data)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    return json["status"] as? String ?? "ok"
                }
                return "ok"
            } catch {
                lastError = error
            }
        }

        throw lastError ?? OpenClawError.requestFailed("无法获取 IronClaw 状态")
    }

    func fetchUsageCost() async throws -> UsageCostPayload {
        let sessions = try await fetchSessionsList(limit: 200, activeMinutes: 525600)
        let totals = sessions.sessions?.reduce(UsageTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, totalCost: 0, inputCost: nil, outputCost: nil, cacheReadCost: nil, cacheWriteCost: nil, missingCostEntries: 0)) { partial, _ in
            partial
        } ?? UsageTotals(input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, totalCost: 0, inputCost: nil, outputCost: nil, cacheReadCost: nil, cacheWriteCost: nil, missingCostEntries: 0)

        return UsageCostPayload(
            updatedAt: Int64(Date().timeIntervalSince1970 * 1000),
            days: 0,
            daily: [],
            totals: totals
        )
    }

    func fetchSessionUsageCost(sessionKey: String) async throws -> UsageCostPayload {
        let history = try await fetchChatHistory(sessionKey: sessionKey, limit: 200)
        let messageCount = history.historyPayload?.messages.count ?? 0
        let totals = UsageTotals(
            input: messageCount,
            output: 0,
            cacheRead: 0,
            cacheWrite: 0,
            totalTokens: messageCount,
            totalCost: 0,
            inputCost: nil,
            outputCost: nil,
            cacheReadCost: nil,
            cacheWriteCost: nil,
            missingCostEntries: 0
        )
        return UsageCostPayload(updatedAt: Int64(Date().timeIntervalSince1970 * 1000), days: 0, daily: [], totals: totals)
    }

    func fetchCronJobs(includeDisabled: Bool = false) async throws -> [CronJob] {
        let payload = try await invokeTool(name: "cron_list", arguments: ["include_disabled": includeDisabled])
        let jobs = payload["jobs"] as? [[String: Any]] ?? []
        let data = try JSONSerialization.data(withJSONObject: jobs)
        return try JSONDecoder().decode([CronJob].self, from: data)
    }

    func fetchCronStatus() async throws -> CronStatus {
        let jobs = try await fetchCronJobs(includeDisabled: true)
        let nextWake = jobs.map { Int64($0.updatedAtMs) }.min()
        return CronStatus(enabled: !jobs.isEmpty, storePath: nil, jobs: jobs.count, nextWakeAtMs: nextWake)
    }

    func fetchCronRuns(jobId: String, limit: Int? = nil) async throws -> [CronRunEntry] {
        let payload = try await invokeTool(name: "cron_runs_read", arguments: ["job_id": jobId, "limit": limit ?? 20])
        let entries = (payload["runs"] as? [[String: Any]] ?? []).map { raw -> [String: Any] in
            [
                "ts": raw["startedAt"] as? Int64 ?? Int64(Date().timeIntervalSince1970 * 1000),
                "jobId": raw["jobId"] as? String ?? jobId,
                "action": "finished",
                "status": raw["status"] as? String ?? "ok",
                "summary": raw["error"] as? String,
                "runAtMs": raw["startedAt"] as? Int64 ?? Int64(Date().timeIntervalSince1970 * 1000),
                "durationMs": raw["durationMs"] as? Int ?? 0,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: entries)
        return try JSONDecoder().decode([CronRunEntry].self, from: data)
    }

    func addCronJob(id: String, schedule: String, action: CronAction, enabled: Bool = true) async throws {
        throw OpenClawError.requestFailed("IronClaw 当前未提供创建 cron 任务接口")
    }

    func updateCronJob(id: String, patch: CronJobPatch) async throws {
        var args: [String: Any] = ["id": id]
        if let enabled = patch.enabled { args["enabled"] = enabled }
        if let schedule = patch.schedule { args["schedule"] = schedule }
        _ = try await invokeTool(name: "cron_update", arguments: args)
    }

    func removeCronJob(id: String) async throws {
        throw OpenClawError.requestFailed("IronClaw 当前未提供删除 cron 任务接口")
    }

    func runCronJob(id: String, mode: String = "force") async throws {
        let result = try await invokeTool(name: "cron_run", arguments: ["id": id, "mode": mode])
        let event = CronEvent(type: "event", event: "cron", payload: .init(jobId: id, action: "finished", runAtMs: Int64(Date().timeIntervalSince1970 * 1000), status: result["ran"] as? Bool == true ? "ok" : "error", summary: result["reason"] as? String, durationMs: nil), seq: nil)
        onCronEvent?(event)
    }

    func fetchSkillsStatus(agentId: String? = nil) async throws -> [Skill] {
        throw OpenClawError.requestFailed("IronClaw 当前未提供技能状态接口")
    }

    func updateSkill(skillKey: String, enabled: Bool? = nil, apiKey: String? = nil, env: [String: String]? = nil) async throws -> SkillUpdateResponse.Payload {
        throw OpenClawError.requestFailed("IronClaw 当前未提供技能更新接口")
    }

    func fetchChatHistory(sessionKey: String, limit: Int = 200) async throws -> ChatHistoryResponse {
        if let threadId = threadIDsBySessionKey[sessionKey] ?? (UUID(uuidString: sessionKey) != nil ? sessionKey : nil) {
            let history = try await fetchThreadHistory(threadId: threadId)
            return ChatHistoryResponse(
                type: "res",
                id: UUID().uuidString,
                ok: true,
                payload: .init(
                    sessionKey: sessionKey,
                    sessionId: threadId,
                    thinkingLevel: "off",
                    messages: Array(threadHistoryMessages(from: history).prefix(limit))
                ),
                result: nil,
                error: nil
            )
        }

        let payload = try await invokeTool(name: "sessions_history", arguments: [
            "session_key": sessionKey,
            "limit": limit,
            "include_tools": true,
        ])
        let historyJSON: [String: Any] = [
            "type": "res",
            "id": UUID().uuidString,
            "ok": true,
            "payload": [
                "sessionKey": sessionKey,
                "sessionId": sessionKey,
                "thinkingLevel": "off",
                "messages": payload["messages"] as? [[String: Any]] ?? [],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: historyJSON)
        return try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
    }

    func fetchSessionsList(limit: Int = 100, activeMinutes: Int = 10080) async throws -> SessionsListResponse {
        let payload = try await invokeTool(name: "sessions_list", arguments: [
            "limit": limit,
            "activeMinutes": activeMinutes,
            "includeDerivedTitles": true,
        ])
        let sessions = (payload["sessions"] as? [[String: Any]] ?? []).map { raw -> [String: Any] in
            [
                "key": raw["key"] as? String ?? "unknown",
                "kind": raw["kind"] as? String,
                "displayName": raw["derivedTitle"] as? String ?? raw["label"] as? String,
                "updatedAt": raw["updatedAt"] as? Int ?? 0,
                "sessionId": raw["id"] as? String ?? raw["key"] as? String ?? UUID().uuidString,
                "channel": raw["kind"] as? String,
                "totalTokens": raw["inputTokens"] as? Int ?? 0,
            ]
        }
        let responseJSON: [String: Any] = [
            "type": "res",
            "ok": true,
            "id": UUID().uuidString,
            "payload": [
                "sessions": sessions,
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        return try JSONDecoder().decode(SessionsListResponse.self, from: data)
    }

    @discardableResult
    func patchThinkingLevel(sessionKey: String, thinkingLevel: String) async throws -> SessionsPatchResponse {
        let responseJSON: [String: Any] = [
            "id": UUID().uuidString,
            "result": [
                "ok": true,
                "entry": [
                    "sessionId": sessionKey,
                    "thinkingLevel": thinkingLevel,
                    "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
                    "model": NSNull(),
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: responseJSON)
        return try JSONDecoder().decode(SessionsPatchResponse.self, from: data)
    }

    struct SessionSyncResult {
        let orphanedLocalSessionIds: [String]
        let serverSessionKeys: [String]
    }

    func syncSessions(localSessions: [ContextGoSession]) async throws -> SessionSyncResult {
        let response = try await fetchSessionsList(limit: 200, activeMinutes: 525600)
        let serverKeys = Set(response.sessions?.map(\.key) ?? [])
        let orphaned = localSessions.compactMap { session -> String? in
            guard let key = session.channelMetadataDict?["sessionKey"] as? String else { return nil }
            return serverKeys.contains(key) ? nil : session.id
        }
        return SessionSyncResult(orphanedLocalSessionIds: orphaned, serverSessionKeys: Array(serverKeys))
    }

    func sendRPC<T: Decodable>(method: String, params: [String: Any]? = nil) async throws -> T {
        if T.self == ConfigGetPayload.self {
            let models = try await fetchModels()
            let payload = ConfigGetPayload(mode: "merge", baseHash: nil, providers: ["ironclaw": .init(apiKey: nil, baseUrl: baseURL.absoluteString, models: models.map(\.id))])
            return payload as! T
        }

        if T.self == ConfigPatchPayload.self {
            throw OpenClawError.requestFailed("IronClaw 当前未提供模型配置写入接口")
        }

        throw OpenClawError.requestFailed("IronClaw 暂未支持 RPC method: \(method)")
    }

    func retrieveBufferedMessage(for sessionKey: String) -> BufferedMessage? {
        cleanupOldBuffers()
        return bufferedMessages[sessionKey]
    }

    func clearBufferedMessage(for sessionKey: String) {
        bufferedMessages.removeValue(forKey: sessionKey)
    }

    func clearAllBufferedMessages() {
        bufferedMessages.removeAll()
        threadIDsBySessionKey.removeAll()
    }

    private func buffer(delta: String, sessionKey: String, runId: String) {
        if bufferedMessages[sessionKey] == nil {
            bufferedMessages[sessionKey] = BufferedMessage(sessionKey: sessionKey, runId: runId, deltas: [], timestamp: Date(), isComplete: false, error: nil)
        }
        bufferedMessages[sessionKey]?.deltas.append(delta)
    }

    private func bufferReplacement(text: String, sessionKey: String, runId: String) {
        bufferedMessages[sessionKey] = BufferedMessage(
            sessionKey: sessionKey,
            runId: runId,
            deltas: text.isEmpty ? [] : [text],
            timestamp: Date(),
            isComplete: false,
            error: nil
        )
    }

    private func markBufferedComplete(sessionKey: String) {
        bufferedMessages[sessionKey]?.isComplete = true
    }

    private func markBufferedError(sessionKey: String, message: String) {
        bufferedMessages[sessionKey]?.isComplete = true
        bufferedMessages[sessionKey]?.error = message
    }

    private func cleanupOldBuffers() {
        let now = Date()
        bufferedMessages = bufferedMessages.filter { _, message in
            now.timeIntervalSince(message.timestamp) < maxBufferAge
        }
    }

    private func removeRun(_ runId: String) {
        runQueue.removeAll { $0 == runId }
        notifyRunQueueChanged()
    }

    private func notifyRunQueueChanged() {
        onRunQueueChanged?(!runQueue.isEmpty)
    }

    private func fetchModels() async throws -> [IronClawModel] {
        let request = try makeRequest(path: "/v1/models", method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(IronClawModelsResponse.self, from: data).data
    }

    private func invokeTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        let request = try makeRequest(
            path: "/tools/invoke",
            method: "POST",
            jsonBody: [
                "tool": name,
                "args": arguments,
            ]
        )
        let (data, response) = try await session.data(for: request)
        try validate(response, data: data, endpoint: "/tools/invoke")
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OpenClawError.decodingFailed
        }
        if let ok = json["ok"] as? Bool, !ok {
            let error = json["error"] as? [String: Any]
            throw OpenClawError.requestFailed(error?["message"] as? String ?? "IronClaw tool invoke failed")
        }
        if let result = json["result"] as? [String: Any],
           let content = result["content"] as? [[String: Any]],
           let text = content.first?["text"] as? String,
           let nestedData = text.data(using: .utf8),
           let nestedJSON = try JSONSerialization.jsonObject(with: nestedData) as? [String: Any] {
            return nestedJSON
        }
        return json["payload"] as? [String: Any] ?? json
    }
}

enum OpenClawError: LocalizedError {
    case notConnected
    case requestFailed(String)
    case decodingFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to IronClaw"
        case .requestFailed(let message):
            return message
        case .decodingFailed:
            return "Failed to decode IronClaw response"
        case .timeout:
            return "Request timed out"
        }
    }
}

private struct IronClawModelsResponse: Decodable {
    let data: [IronClawModel]
}

private struct IronClawModel: Decodable {
    let id: String
}

