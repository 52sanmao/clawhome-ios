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
    private let diagnostics = ClawHomeLogStore.shared

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

    private func log(_ message: String) {
        diagnostics.append(message)
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

        let tokenState = token.isEmpty ? "未携带 Token" : "已携带 Token(length=\(token.count))"
        log("准备请求 \(method) \(path) host=\(url.host ?? "unknown") \(tokenState)")
        return request
    }

    private func describeHTTPError(data: Data?, statusCode: Int) -> String {
        if let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let data,
           let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if statusCode == 401 {
            return "鉴权失败，请检查 Bearer Token 是否有效"
        }
        return "IronClaw request failed (HTTP \(statusCode))"
    }

    private func logFailure(_ message: String, endpoint: String, error: Error) {
        log("\(message) endpoint=\(endpoint) error=\(error.localizedDescription)")
    }

    private func logChatState(runId: String, sessionKey: String, state: String, detail: String) {
        log("聊天状态 run=\(runId) session=\(sessionKey) state=\(state) \(detail)")
    }

    private func extractThreadTerminalError(from turn: IronClawThreadTurn) -> String? {
        if let error = turn.error?.trimmingCharacters(in: .whitespacesAndNewlines), !error.isEmpty {
            return error
        }
        if let response = turn.response?.trimmingCharacters(in: .whitespacesAndNewlines), !response.isEmpty,
           turn.state.lowercased().contains("fail") {
            return response
        }
        return nil
    }

    private func removeRun(_ runId: String, reason: String? = nil) {
        runQueue.removeAll { $0 == runId }
        if let reason, !reason.isEmpty {
            log("结束运行 run=\(runId) reason=\(reason) 剩余活动运行数=\(runQueue.count)")
        } else {
            log("结束运行 run=\(runId) 剩余活动运行数=\(runQueue.count)")
        }
        notifyRunQueueChanged()
    }

    private func notifyRunQueueChanged() {
        log("活动运行队列变更 count=\(runQueue.count)")
        onRunQueueChanged?(!runQueue.isEmpty)
    }

    private func validate(_ response: URLResponse, data: Data? = nil, endpoint: String? = nil) throws {
        guard let http = response as? HTTPURLResponse else {
            log("请求失败：无效响应对象 endpoint=\(endpoint ?? "unknown")")
            throw OpenClawError.requestFailed("Invalid IronClaw response")
        }
        log("收到 HTTP \(http.statusCode) endpoint=\(endpoint ?? "unknown")")
        guard (200 ..< 300).contains(http.statusCode) else {
            if http.statusCode == 404, endpoint == "/tools/invoke" {
                log("扩展接口未启用 endpoint=/tools/invoke status=404")
                throw OpenClawError.requestFailed("当前 IronClaw 部署未启用工具接口（/tools/invoke），该功能不可用")
            }
            let message = describeHTTPError(data: data, statusCode: http.statusCode)
            log("HTTP 请求失败 endpoint=\(endpoint ?? "unknown") status=\(http.statusCode) message=\(message)")
            throw OpenClawError.requestFailed(message)
        }
    }

    private func describeConnectionState(_ state: ConnectionState) -> String {
        switch state {
        case .connected:
            return "connected"
        case .connecting:
            return "connecting"
        case .disconnected:
            return "disconnected"
        case .error(let message):
            return "error(\(message))"
        }
    }

    private func updateConnectionState(_ state: ConnectionState) {
        connectionState = state
        log("HTTP 主链路状态=\(describeConnectionState(state))")
    }

    private func updateConnected(_ connected: Bool) {
        isConnected = connected
        log("HTTP 主链路连接标记=\(connected ? "true" : "false")")
    }

    private func updatePresenceInfo(_ info: ConnectResponse.HelloPayload.PresenceInfo?) {
        presenceInfo = info
        if let info {
            log("Presence 已更新 online=\(info.online) model=\(info.model)")
        } else {
            log("Presence 已清空")
        }
    }

    func connect() {
        guard connectionState != .connecting else {
            log("忽略重复 connect()：当前已在连接中")
            return
        }
        log("开始验证 HTTP 聊天主链路 baseURL=\(baseURL.absoluteString)")
        updateConnectionState(.connecting)

        Task {
            do {
                _ = try await fetchModels()
                updateConnected(true)
                updateConnectionState(.connected)
                updatePresenceInfo(ConnectResponse.HelloPayload.PresenceInfo(online: true, model: "IronClaw"))
                log("HTTP 聊天主链路验证成功")
            } catch {
                updateConnected(false)
                updateConnectionState(.error(error.localizedDescription))
                logFailure("HTTP 聊天主链路验证失败", endpoint: "/v1/models", error: error)
            }
        }
    }

    func disconnect() {
        log("断开 HTTP 聊天主链路")
        currentResponseTask?.cancel()
        currentResponseTask = nil
        updateConnected(false)
        updatePresenceInfo(nil)
        updateConnectionState(.disconnected)
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
        guard isConnected else {
            log("拒绝发送消息：HTTP 主链路当前未连接")
            throw OpenClawError.notConnected
        }

        let resolvedSessionKey = sessionKey ?? "agent:main:operator:default"
        let runId = "hermes-run-\(UUID().uuidString)"
        log("开始发送聊天消息 run=\(runId) session=\(resolvedSessionKey) 文本长度=\(message.count) 附件数=\(attachments.count)")
        runQueue.append(runId)
        notifyRunQueueChanged()
        onRunAccepted?(runId)
        onLifecycleStart?(runId)
        if let thinking, !thinking.isEmpty {
            log("发送前携带 thinking 提示 run=\(runId) length=\(thinking.count)")
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
            logChatState(runId: runId, sessionKey: sessionKey, state: "resolving_thread", detail: "开始解析或创建线程")
            let threadId = try await resolveThreadID(for: sessionKey)
            logChatState(runId: runId, sessionKey: sessionKey, state: "accepted", detail: "thread=\(threadId)")
            onChatStateEvent?(ChatStateEvent(runId: runId, sessionKey: sessionKey, state: "accepted", text: nil, thinking: nil, stopReason: nil, errorMessage: nil))

            let baselineHistory = try await fetchThreadHistory(threadId: threadId)
            let baselineTurnCount = baselineHistory.turns.count
            logChatState(runId: runId, sessionKey: sessionKey, state: "history_baseline", detail: "thread=\(threadId) turns=\(baselineTurnCount)")
            let content = composeThreadMessageContent(message: message, attachments: attachments)

            try await postThreadMessage(content: content, threadId: threadId)
            logChatState(runId: runId, sessionKey: sessionKey, state: "message_sent", detail: "thread=\(threadId) payloadLength=\(content.count)")
            let poll = try await waitForThreadTurn(threadId: threadId, afterTurnCount: baselineTurnCount)
            let responseText = (poll.latestTurn.response ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            if !responseText.isEmpty {
                bufferReplacement(text: responseText, sessionKey: sessionKey, runId: runId)
                onAgentStreamDelta?(responseText)
                logChatState(runId: runId, sessionKey: sessionKey, state: "response_ready", detail: "thread=\(threadId) 响应长度=\(responseText.count)")
            } else {
                logChatState(runId: runId, sessionKey: sessionKey, state: "response_empty", detail: "thread=\(threadId) 已到终态但响应为空")
            }

            markBufferedComplete(sessionKey: sessionKey)
            onChatStateEvent?(ChatStateEvent(runId: runId, sessionKey: sessionKey, state: "final", text: responseText, thinking: nil, stopReason: nil, errorMessage: nil))
            onLifecycleEnd?(runId)
            onAgentComplete?()
            removeRun(runId, reason: "completed")
        } catch is CancellationError {
            logChatState(runId: runId, sessionKey: sessionKey, state: "cancelled", detail: "聊天任务被取消")
            removeRun(runId, reason: "cancelled")
        } catch {
            let message = error.localizedDescription
            markBufferedError(sessionKey: sessionKey, message: message)
            logChatState(runId: runId, sessionKey: sessionKey, state: "error", detail: message)
            onChatStateEvent?(ChatStateEvent(runId: runId, sessionKey: sessionKey, state: "error", text: nil, thinking: nil, stopReason: nil, errorMessage: message))
            onLifecycleError?(runId, message)
            onAgentError?(message)
            removeRun(runId, reason: "error")
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
            log("复用已有线程 session=\(sessionKey) thread=\(existing)")
            return existing
        }
        if UUID(uuidString: sessionKey) != nil {
            threadIDsBySessionKey[sessionKey] = sessionKey
            log("sessionKey 本身就是线程 ID session=\(sessionKey)")
            return sessionKey
        }
        log("未找到现有线程，准备新建线程 session=\(sessionKey)")
        let created = try await createThread()
        threadIDsBySessionKey[sessionKey] = created.id
        log("线程创建完成 session=\(sessionKey) thread=\(created.id)")
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
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data, endpoint: "/api/chat/send")
            log("聊天发送成功 thread=\(threadId)")
        } catch {
            logFailure("聊天发送失败 thread=\(threadId)", endpoint: "/api/chat/send", error: error)
            throw error
        }
    }

    private func waitForThreadTurn(threadId: String, afterTurnCount: Int, timeout: TimeInterval = 45) async throws -> ThreadPollResult {
        let deadline = Date().addingTimeInterval(timeout)
        var attempt = 0
        while Date() < deadline {
            attempt += 1
            let history = try await fetchThreadHistory(threadId: threadId)
            let latestState = history.turns.last?.state ?? "none"
            log("轮询聊天历史 thread=\(threadId) attempt=\(attempt) turns=\(history.turns.count) latestState=\(latestState)")
            if let latest = history.turns.last,
               history.turns.count > afterTurnCount,
               latest.isTerminal {
                if latest.state.lowercased().contains("fail") {
                    let message = extractThreadTerminalError(from: latest) ?? "聊天线程失败，但服务端未返回详细错误"
                    log("聊天线程终态失败 thread=\(threadId) state=\(latest.state) message=\(message)")
                    throw OpenClawError.requestFailed(message)
                }
                log("聊天线程达到终态 thread=\(threadId) state=\(latest.state)")
                return ThreadPollResult(history: history, latestTurn: latest)
            }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        log("聊天历史轮询超时 thread=\(threadId) timeout=\(timeout)")
        throw OpenClawError.timeout
    }

    private func fetchThreadHistory(threadId: String) async throws -> IronClawThreadHistoryResponse {
        let encoded = threadId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? threadId
        let request = try makeRequest(path: "/api/chat/history?thread_id=\(encoded)", method: "GET")
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data, endpoint: "/api/chat/history")
            let decoded = try JSONDecoder.snakeCase.decode(IronClawThreadHistoryResponse.self, from: data)
            return decoded
        } catch {
            logFailure("拉取聊天历史失败 thread=\(threadId)", endpoint: "/api/chat/history", error: error)
            throw error
        }
    }

    private func createThread() async throws -> IronClawThreadInfo {
        let request = try makeRequest(path: "/api/chat/thread/new", method: "POST")
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data, endpoint: "/api/chat/thread/new")
            let decoded = try JSONDecoder.snakeCase.decode(IronClawThreadInfo.self, from: data)
            log("创建聊天线程成功 thread=\(decoded.id)")
            return decoded
        } catch {
            logFailure("创建聊天线程失败", endpoint: "/api/chat/thread/new", error: error)
            throw error
        }
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
        let error: String?

        var isTerminal: Bool {
            let normalized = state.lowercased()
            return normalized.contains("completed") || normalized.contains("failed") || normalized.contains("accepted")
        }
    }

    func abortChat(sessionKey: String? = nil, runId: String? = nil) async throws -> Int {
        log("请求停止聊天 run=\(runId ?? "unknown") session=\(sessionKey ?? "unknown")")
        currentResponseTask?.cancel()
        currentResponseTask = nil
        let resolvedRunId = runId ?? runQueue.first
        if let resolvedRunId {
            removeRun(resolvedRunId, reason: "stopped")
            onChatStateEvent?(ChatStateEvent(runId: resolvedRunId, sessionKey: sessionKey ?? "", state: "aborted", text: nil, thinking: nil, stopReason: "stopped", errorMessage: nil))
            onLifecycleError?(resolvedRunId, "stopped")
            onAgentComplete?()
            return 1
        }
        log("停止聊天时没有活动 run")
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
                log("开始探测健康状态 endpoint=\(path)")
                let request = try makeRequest(path: path, method: "GET")
                let (data, response) = try await session.data(for: request)
                try validate(response, data: data, endpoint: path)
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let status = json["status"] as? String ?? "ok"
                    log("健康状态探测成功 endpoint=\(path) status=\(status)")
                    return status
                }
                log("健康状态探测成功 endpoint=\(path) status=ok")
                return "ok"
            } catch {
                logFailure("健康状态探测失败", endpoint: path, error: error)
                lastError = error
            }
        }

        throw lastError ?? OpenClawError.requestFailed("无法获取 IronClaw 状态")
    }

    func fetchCronJobs(includeDisabled: Bool = false) async throws -> [CronJob] {
        log("开始刷新 routines 列表 includeDisabled=\(includeDisabled)")
        let request = try makeRequest(path: "/api/routines", method: "GET")
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data, endpoint: "/api/routines")
            let decoded = try JSONDecoder.snakeCase.decode(RoutineListResponseDTO.self, from: data)
            let jobs = decoded.routines.compactMap { routine in
                if !includeDisabled, routine.enabled == false {
                    return nil
                }
                return CronJob(dto: routine)
            }
            log("routines 列表刷新成功 count=\(jobs.count)")
            return jobs
        } catch {
            logFailure("刷新 routines 列表失败", endpoint: "/api/routines", error: error)
            throw error
        }
    }

    func fetchCronStatus() async throws -> CronStatus {
        let jobs = try await fetchCronJobs(includeDisabled: true)
        let nextWake = jobs.compactMap { $0.state.nextWakeAtMs }.min()
        let enabledJobs = jobs.filter { $0.state.lastRunStatus != "disabled" }
        let status = CronStatus(enabled: !enabledJobs.isEmpty, storePath: nil, jobs: jobs.count, nextWakeAtMs: nextWake)
        log("routines 状态汇总 enabled=\(status.enabled) jobs=\(status.jobs)")
        return status
    }

    func fetchCronRuns(jobId: String, limit: Int? = nil) async throws -> [CronRunEntry] {
        let escapedJobId = jobId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? jobId
        log("开始刷新 routine runs job=\(jobId) limit=\(limit.map(String.init) ?? "nil")")
        let request = try makeRequest(path: "/api/routines/\(escapedJobId)/runs", method: "GET")
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data, endpoint: "/api/routines/{id}/runs")
            let decoded = try JSONDecoder.snakeCase.decode(RoutineRunsResponseDTO.self, from: data)
            let runs = decoded.runs.map { CronRunEntry(dto: $0, fallbackJobId: jobId) }
            let limitedRuns = limit.map { Array(runs.prefix($0)) } ?? runs
            log("routine runs 刷新成功 job=\(jobId) count=\(limitedRuns.count)")
            return limitedRuns
        } catch {
            logFailure("刷新 routine runs 失败 job=\(jobId)", endpoint: "/api/routines/{id}/runs", error: error)
            throw error
        }
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


    func addCronJob(id: String, schedule: String, action: CronAction, enabled: Bool = true) async throws {
        throw OpenClawError.requestFailed("IronClaw 当前未提供创建 cron 任务接口")
    }

    func updateCronJob(id: String, patch: CronJobPatch) async throws {
        guard patch.schedule == nil, let enabled = patch.enabled else {
            throw OpenClawError.requestFailed("IronClaw 当前仅支持启用或停用现有任务")
        }
        let escapedJobId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        log("开始切换 routine 开关 job=\(id) enabled=\(enabled)")
        let request = try makeRequest(
            path: "/api/routines/\(escapedJobId)/toggle",
            method: "POST",
            jsonBody: ["enabled": enabled]
        )
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data, endpoint: "/api/routines/{id}/toggle")
            log("切换 routine 开关成功 job=\(id) enabled=\(enabled)")
        } catch {
            logFailure("切换 routine 开关失败 job=\(id)", endpoint: "/api/routines/{id}/toggle", error: error)
            throw error
        }
    }

    func removeCronJob(id: String) async throws {
        throw OpenClawError.requestFailed("IronClaw 当前未提供删除 cron 任务接口")
    }

    func runCronJob(id: String, mode: String = "force") async throws {
        let escapedJobId = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        log("开始触发 routine job=\(id) mode=\(mode)")
        let request = try makeRequest(
            path: "/api/routines/\(escapedJobId)/trigger",
            method: "POST",
            jsonBody: ["mode": mode]
        )
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data, endpoint: "/api/routines/{id}/trigger")
            let event = CronEvent(
                type: "event",
                event: "cron",
                payload: .init(
                    jobId: id,
                    action: "finished",
                    runAtMs: Int64(Date().timeIntervalSince1970 * 1000),
                    status: "ok",
                    summary: nil,
                    durationMs: nil
                ),
                seq: nil
            )
            log("触发 routine 成功 job=\(id)")
            onCronEvent?(event)
        } catch {
            logFailure("触发 routine 失败 job=\(id)", endpoint: "/api/routines/{id}/trigger", error: error)
            throw error
        }
    }

    func fetchChatHistory(sessionKey: String, limit: Int = 200) async throws -> ChatHistoryResponse {
        log("开始读取聊天历史 session=\(sessionKey) limit=\(limit)")
        if let threadId = threadIDsBySessionKey[sessionKey] ?? (UUID(uuidString: sessionKey) != nil ? sessionKey : nil) {
            let history = try await fetchThreadHistory(threadId: threadId)
            let response = ChatHistoryResponse(
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
            log("读取聊天历史成功 session=\(sessionKey) source=http messages=\(response.historyPayload?.messages.count ?? 0)")
            return response
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
        let response = try JSONDecoder().decode(ChatHistoryResponse.self, from: data)
        log("读取聊天历史成功 session=\(sessionKey) source=tool messages=\(response.historyPayload?.messages.count ?? 0)")
        return response
    }

    func fetchSessionsList(limit: Int = 100, activeMinutes: Int = 10080) async throws -> SessionsListResponse {
        log("开始刷新 sessions 列表 limit=\(limit) activeMinutes=\(activeMinutes)")
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
        let response = try JSONDecoder().decode(SessionsListResponse.self, from: data)
        log("sessions 列表刷新成功 count=\(response.sessions?.count ?? 0)")
        return response
    }

    func fetchSkillsStatus(agentId: String? = nil) async throws -> [Skill] {
        throw OpenClawError.requestFailed("IronClaw 当前未提供技能状态接口")
    }

    func updateSkill(skillKey: String, enabled: Bool? = nil, apiKey: String? = nil, env: [String: String]? = nil) async throws -> SkillUpdateResponse.Payload {
        throw OpenClawError.requestFailed("IronClaw 当前未提供技能更新接口")
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


    private func fetchModels() async throws -> [IronClawModel] {
        log("开始探测模型列表 /v1/models")
        let request = try makeRequest(path: "/v1/models", method: "GET")
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data, endpoint: "/v1/models")
            let models = try JSONDecoder().decode(IronClawModelsResponse.self, from: data).data
            log("模型列表探测成功 count=\(models.count)")
            return models
        } catch {
            logFailure("模型列表探测失败", endpoint: "/v1/models", error: error)
            throw error
        }
    }

    private func invokeTool(name: String, arguments: [String: Any]) async throws -> [String: Any] {
        log("开始调用扩展工具 tool=\(name)")
        let request = try makeRequest(
            path: "/tools/invoke",
            method: "POST",
            jsonBody: [
                "tool": name,
                "args": arguments,
            ]
        )
        do {
            let (data, response) = try await session.data(for: request)
            try validate(response, data: data, endpoint: "/tools/invoke")
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                log("扩展工具返回无法解析 JSON tool=\(name)")
                throw OpenClawError.decodingFailed
            }
            if let ok = json["ok"] as? Bool, !ok {
                let error = json["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "IronClaw tool invoke failed"
                log("扩展工具调用失败 tool=\(name) message=\(message)")
                throw OpenClawError.requestFailed(message)
            }
            if let result = json["result"] as? [String: Any],
               let content = result["content"] as? [[String: Any]],
               let text = content.first?["text"] as? String,
               let nestedData = text.data(using: .utf8),
               let nestedJSON = try JSONSerialization.jsonObject(with: nestedData) as? [String: Any] {
                log("扩展工具调用成功 tool=\(name) source=result.content")
                return nestedJSON
            }
            log("扩展工具调用成功 tool=\(name) source=payload")
            return json["payload"] as? [String: Any] ?? json
        } catch {
            logFailure("扩展工具调用异常 tool=\(name)", endpoint: "/tools/invoke", error: error)
            throw error
        }
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

