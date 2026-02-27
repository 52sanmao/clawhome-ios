//
//  OpenClawClient.swift
//  contextgo
//
//  High-level OpenClaw Gateway API Client
//

import Foundation
import Combine
import UIKit
import CryptoKit

@MainActor
class OpenClawClient: ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var presenceInfo: ConnectResponse.HelloPayload.PresenceInfo?

    // ✅ Expose runQueue for UI (read-only)
    var activeRunQueue: [String] {
        runQueue
    }

    var hasActiveRuns: Bool {
        !runQueue.isEmpty
    }

    // MARK: - Private Properties
    private var webSocketManager: WebSocketManager
    private var pendingRequests: [String: (Result<Data, Error>) -> Void] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var sessionDefaults: HelloResponse.Snapshot.SessionDefaults?
    private var secret: String?  // Secret from WebSocket URL for challenge-response auth
    private var hasCompletedHandshake = false  // ✅ Track if we've completed the initial handshake

    // ✅ FIFO runQueue: Track our own runIds IN ORDER (for stopping oldest first)
    private var runQueue: [String] = []  // Changed from Set to Array for FIFO order
    private var pendingRunHints: [String: String] = [:]  // requestId -> provisional runId (idempotencyKey)
    private var terminalRunIds: Set<String> = []
    private var terminalRunOrder: [String] = []
    private let terminalRunHistoryLimit = 256

    // Backward compatibility: expose as Set for checking membership
    private var activeRunIds: Set<String> {
        Set(runQueue)
    }

    // Track other channels' active runs for status display
    private var otherChannelRuns: Set<String> = []
    private var activeChannels: Set<String> = []  // Track which channels are active
    private var runIdToChannel: [String: String] = [:]  // Map runId to channel name
    private var channelLabels: [String: String] = [:]  // Map channel id to display name (from Gateway)

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

    // MARK: - Streaming (for our own messages)
    var onAgentStreamDelta: ((String) -> Void)?
    var onAgentThinkingDelta: ((String) -> Void)?
    var onAgentComplete: (() -> Void)?  // Changed: no text parameter, just completion signal
    var onAgentError: ((String) -> Void)?
    var onRunAccepted: ((String) -> Void)?  // Resolved runId after ack
    var onChatStateEvent: ((ChatStateEvent) -> Void)?  // chat.delta/final/aborted/error channel

    // MARK: - Tool Execution Callbacks (NEW)
    var onToolExecutionStart: ((String, String, String, String?) -> Void)?  // (runId, toolId, toolName, input)
    var onToolExecutionUpdate: ((String, String, String) -> Void)?  // (runId, toolId, partialOutput)
    var onToolExecutionResult: ((String, String, String?, String?) -> Void)?  // (runId, toolId, output, error)

    // MARK: - Lifecycle Callbacks (NEW)
    var onLifecycleStart: ((String) -> Void)?  // Agent started thinking (runId)
    var onLifecycleEnd: ((String) -> Void)?  // Agent finished (runId)
    var onLifecycleError: ((String, String) -> Void)?  // (runId, error)

    // MARK: - Compaction Callback (NEW)
    var onMemoryCompaction: ((Int) -> Void)?  // (messageCount) - Agent compacted memory
    var onCompactionEvent: ((CompactionEvent) -> Void)?  // phase-driven compaction status

    // MARK: - Run Queue State Callback (NEW)
    var onRunQueueChanged: ((Bool) -> Void)?  // (hasActiveRuns) - For stop button state

    // MARK: - Cron Job Notifications
    var onCronEvent: ((CronEvent) -> Void)?  // Notify when cron job executes

    // MARK: - Other Channel Activity
    var onOtherChannelActivity: ((Set<String>, Bool) -> Void)?  // (channels, isActive)

    // MARK: - Message Buffer (for offline message caching)
    struct BufferedMessage: Codable {
        let sessionKey: String
        let runId: String
        var deltas: [String]  // Accumulated deltas
        let timestamp: Date
        var isComplete: Bool
        var error: String?

        var fullText: String {
            return deltas.joined()
        }
    }

    private var messageBuffer: [String: BufferedMessage] = [:]  // sessionKey -> buffered message
    private let maxBufferAge: TimeInterval = 3600  // 1 hour max buffer time

    // MARK: - Device Info
    private lazy var clientInfo: ConnectRequest.ConnectParams.ClientInfo = {
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let deviceName = UIDevice.current.name
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"

        // ✅ Use standard operator client ID to avoid Control UI security checks
        return ConnectRequest.ConnectParams.ClientInfo(
            id: "openclaw-ios",
            displayName: "Context Go (\(deviceName))",
            version: appVersion,
            platform: "ios",
            mode: "ui",
            instanceId: deviceId
        )
    }()

    // MARK: - Initialization
    nonisolated init(url: URL) {
        let urlString = url.absoluteString
        guard let wsURL = URL(string: urlString) else {
            fatalError("Invalid Gateway URL: \(Self.redactedURLString(from: urlString))")
        }
        self.webSocketManager = WebSocketManager(url: wsURL)
        // Extract secret from URL query parameters
        self.secret = Self.extractSecret(from: wsURL)
        setupWebSocketCallbacks(manager: self.webSocketManager)
        setupStateBindings()
    }

    // MARK: - Helper Methods

    nonisolated private static func redactedURLString(from raw: String) -> String {
        guard let url = URL(string: raw) else { return raw }
        return redactedURLString(from: url)
    }

    nonisolated private static func redactedURLString(from url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "\(url.scheme ?? "ws")://\(url.host ?? "unknown")"
    }

    /// Extract secret parameter from WebSocket URL
    /// Supports "secret", "token", and "password" query parameters
    nonisolated private static func extractSecret(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems else {
            return nil
        }

        // Try to find "secret", "token", or "password" parameter
        if let secret = queryItems.first(where: { $0.name == "secret" })?.value {
            print("[OpenClaw] 🔑 Found credential in Gateway URL (secret parameter)")
            return secret
        } else if let token = queryItems.first(where: { $0.name == "token" })?.value {
            print("[OpenClaw] 🔑 Found credential in Gateway URL (token parameter)")
            return token
        } else if let password = queryItems.first(where: { $0.name == "password" })?.value {
            print("[OpenClaw] 🔑 Found credential in Gateway URL (password parameter)")
            return password
        } else {
            print("[OpenClaw] ⚠️ No secret, token, or password parameter found in URL")
            return nil
        }
    }

    /// Calculate HMAC-SHA256 signature for challenge-response
    private func calculateSignature(secret: String, nonce: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let data = Data(nonce.utf8)
        let signature = HMAC<SHA256>.authenticationCode(for: data, using: key)
        return Data(signature).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Setup
    nonisolated private func setupWebSocketCallbacks(manager: WebSocketManager) {
        manager.onConnected = { [weak self] in
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                // ✅ Protocol v3: Server sends hello-ok automatically, no need to send ConnectRequest
                // Just wait for the server's hello-ok message
                print("[OpenClaw] 🔌 WebSocket connected, waiting for hello-ok from server...")
            }
        }

        manager.onDisconnected = { [weak self] in
            Task { @MainActor [weak self] in
                self?.isConnected = false
                self?.presenceInfo = nil
                self?.sessionDefaults = nil
                // ✅ Don't reset hasCompletedHandshake here - we want to skip handshake on reconnect
            }
        }

        manager.onMessageReceived = { [weak self] data in
            Task { @MainActor in
                self?.handleMessage(data)
            }
        }
    }

    nonisolated private func setupStateBindings() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.webSocketManager.$connectionState
                .receive(on: DispatchQueue.main)
                .assign(to: &self.$connectionState)
        }
    }

    // MARK: - Public API

    /// Update Gateway URL and reconnect
    func updateURL(_ newURL: URL) {
        print("[OpenClaw] Updating Gateway URL to: \(Self.redactedURLString(from: newURL))")
        // Extract secret from new URL
        self.secret = Self.extractSecret(from: newURL)
        // Disconnect current connection
        disconnect()
        // Create new WebSocket manager with updated URL
        let newManager = WebSocketManager(url: newURL)
        setupWebSocketCallbacks(manager: newManager)
        webSocketManager = newManager
        // Setup state bindings for the new manager
        setupStateBindings()
        // Connect to new URL
        connect()
    }

    func connect() {
        webSocketManager.connect()
    }

    func disconnect() {
        webSocketManager.disconnect()
        isConnected = false
        presenceInfo = nil
        sessionDefaults = nil
        hasCompletedHandshake = false  // ✅ Reset handshake flag on intentional disconnect
        runQueue.removeAll()  // Clear runQueue on disconnect
        pendingRunHints.removeAll()
        terminalRunIds.removeAll()
        terminalRunOrder.removeAll()
        notifyRunQueueChanged()  // Notify stop button state
        otherChannelRuns.removeAll()  // Clear other channel tracking
        activeChannels.removeAll()  // Clear active channels
        runIdToChannel.removeAll()  // Clear channel mappings
    }

    /// Send a message to the AI agent
    func sendMessage(
        _ message: String,
        thinking: String? = nil,
        sessionKey: String? = nil,  // Optional: use a specific sessionKey for isolated history
        attachments: [OpenClawAttachment] = []  // ✅ NEW: Support attachments
    ) async throws -> String {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let idempotencyKey = "msg-\(Date().timeIntervalSince1970)-\(UUID().uuidString)"

        // ✅ Track runId in FIFO order (append to end of queue)
        runQueue.append(idempotencyKey)
        pendingRunHints[requestId] = idempotencyKey
        forgetTerminalRun(idempotencyKey)
        notifyRunQueueChanged()  // Notify stop button state
        print("[OpenClaw] Tracking runId (pre-send): \(idempotencyKey), queue size: \(runQueue.count)")

        let request = AgentRequest(
            id: requestId,
            params: AgentRequest.AgentParams(
                message: message,
                idempotencyKey: idempotencyKey,
                thinking: thinking,
                sessionKey: sessionKey ?? sessionDefaults?.mainSessionKey,  // Use custom sessionKey or default
                agentId: sessionDefaults?.defaultAgentId,
                sessionId: nil,  // Not used for session isolation
                lane: nil,
                deliver: nil,
                timeout: nil,
                extraSystemPrompt: nil,
                attachments: attachments.isEmpty ? nil : attachments  // ✅ NEW: Pass attachments
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            // Store callback
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    let provisionalRunId = self.pendingRunHints.removeValue(forKey: requestId) ?? idempotencyKey
                    if let response = try? JSONDecoder().decode(AgentResponse.self, from: data) {
                        if response.ok {
                            let resolvedRunId = response.payload?.runId ?? provisionalRunId
                            continuation.resume(returning: resolvedRunId)
                        } else {
                            let errorMessage = response.error?.message ?? "Unknown error"
                            continuation.resume(throwing: OpenClawError.requestFailed(errorMessage))
                        }
                    } else {
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            // Send request
            webSocketManager.send(request)

            // Timeout after 60 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    self?.pendingRunHints.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// Abort ongoing chat generation
    func abortChat(sessionKey: String? = nil, runId: String? = nil) async throws -> Int {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = AbortRequest(
            id: requestId,
            params: AbortRequest.AbortParams(
                sessionKey: sessionKey ?? sessionDefaults?.mainSessionKey ?? "main",
                runId: runId
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    // Debug: print raw response
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("[OpenClaw] 🔍 Abort response: \(jsonString)")
                    }

                    if let response = try? JSONDecoder().decode(AbortResponse.self, from: data) {
                        if response.ok {
                            let abortedCount = response.payload?.aborted ?? 0
                            print("[OpenClaw] ✅ Aborted \(abortedCount) run(s)")
                            continuation.resume(returning: abortedCount)
                        } else {
                            let errorMessage = response.error?.message ?? "Abort failed"
                            print("[OpenClaw] ❌ Abort failed: \(errorMessage)")
                            continuation.resume(throwing: OpenClawError.requestFailed(errorMessage))
                        }
                    } else {
                        print("[OpenClaw] ❌ Failed to decode AbortResponse")
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            // Timeout after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// Abort the oldest run in the queue (FIFO order)
    func abortOldestRun() async throws -> Int {
        guard let oldestRunId = runQueue.first else {
            print("[OpenClaw] No active runs to abort")
            return 0
        }

        print("[OpenClaw] Aborting oldest run: \(oldestRunId)")
        return try await abortChat(
            sessionKey: sessionDefaults?.mainSessionKey ?? "main",
            runId: oldestRunId
        )
    }

    /// Check gateway health
    func checkHealth() async throws -> String {
        let requestId = UUID().uuidString
        let request = HealthRequest(id: requestId)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(HealthResponse.self, from: data) {
                        let status = response.payload?.status ?? "unknown"
                        continuation.resume(returning: status)
                    } else {
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            // Timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// Fetch usage cost statistics from Gateway (usage.cost API)
    func fetchUsageCost() async throws -> UsageCostPayload {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = UsageCostRequest(id: requestId)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    // Debug: Print raw JSON
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("[UsageCost] Raw JSON: \(jsonString)")
                    }

                    if let response = try? JSONDecoder().decode(UsageCostResponse.self, from: data) {
                        if response.ok, let payload = response.payload {
                            continuation.resume(returning: payload)
                        } else {
                            continuation.resume(throwing: OpenClawError.requestFailed("Failed to fetch usage cost"))
                        }
                    } else {
                        // Try to decode and print error details
                        do {
                            let _ = try JSONDecoder().decode(UsageCostResponse.self, from: data)
                        } catch {
                            print("[UsageCost] Decoding error: \(error)")
                        }
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            // Timeout after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    func fetchSessionUsageCost(sessionKey: String) async throws -> UsageCostPayload {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let keysToTry = Self.sessionUsageKeyCandidates(from: sessionKey)
        var lastError: Error?

        for key in keysToTry {
            do {
                return try await requestSessionUsageCost(sessionKey: key)
            } catch {
                lastError = error
                print("[UsageCost] Failed sessions.usage with key '\(key)': \(error)")
            }
        }

        throw lastError ?? OpenClawError.requestFailed("Failed to fetch session usage")
    }

    private func requestSessionUsageCost(sessionKey: String) async throws -> UsageCostPayload {
        let requestId = UUID().uuidString
        let request = SessionUsageRequest(id: requestId, sessionKey: sessionKey)

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(GenericRPCResponse<SessionUsageResponse.Payload>.self, from: data),
                       response.ok,
                       let payload = response.payload,
                       let session = payload.sessions.first(where: { $0.key == sessionKey }) ?? payload.sessions.first,
                       let usage = session.usage {
                        continuation.resume(returning: usage.toUsageCostPayload(updatedAt: payload.updatedAt))
                    } else if let errorResponse = try? JSONDecoder().decode(GenericRPCResponse<SessionUsageResponse.Payload>.self, from: data),
                              let message = errorResponse.error?.message,
                              !message.isEmpty {
                        continuation.resume(throwing: OpenClawError.requestFailed(message))
                    } else {
                        continuation.resume(throwing: OpenClawError.requestFailed("Failed to fetch session usage"))
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    nonisolated private static func sessionUsageKeyCandidates(from sessionKey: String) -> [String] {
        let normalized = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return []
        }

        var keys: [String] = [normalized]
        if let stripped = stripAgentPrefix(from: normalized), !stripped.isEmpty, stripped != normalized {
            keys.append(stripped)
        }
        return keys
    }

    nonisolated private static func stripAgentPrefix(from sessionKey: String) -> String? {
        let parts = sessionKey.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count >= 3,
              parts[0].lowercased() == "agent" else {
            return nil
        }
        return parts.dropFirst(2).joined(separator: ":")
    }

    // MARK: - Cron APIs

    /// 列出所有定时任务
    func fetchCronJobs(includeDisabled: Bool = false) async throws -> [CronJob] {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = CronListRequest(
            id: requestId,
            params: CronListRequest.CronListParams(includeDisabled: includeDisabled)
        )

        // Debug: Print the request being sent
        if let requestData = try? JSONEncoder().encode(request),
           let requestJson = String(data: requestData, encoding: .utf8) {
            print("[CronJobs] 📤 Sending request: \(requestJson)")
        }
        print("[CronJobs] 📤 Request ID: \(requestId)")

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    // Debug: Print raw JSON
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("[CronJobs] 📥 Raw JSON response: \(jsonString)")
                    }

                    if let response = try? JSONDecoder().decode(CronListResponse.self, from: data) {
                        if response.ok {
                            let jobs = response.payload?.jobs ?? []
                            print("[CronJobs] ✅ Successfully decoded \(jobs.count) jobs")
                            continuation.resume(returning: jobs)
                        } else {
                            continuation.resume(throwing: OpenClawError.requestFailed("Failed to fetch cron jobs"))
                        }
                    } else {
                        // Try to decode and print error details
                        do {
                            let _ = try JSONDecoder().decode(CronListResponse.self, from: data)
                        } catch {
                            print("[CronJobs] ❌ Decoding error: \(error)")
                        }
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// 查询定时任务服务状态
    func fetchCronStatus() async throws -> CronStatus {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = CronStatusRequest(
            id: requestId,
            params: CronStatusRequest.EmptyParams()
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(CronStatusResponse.self, from: data),
                       response.ok,
                       let status = response.payload {
                        continuation.resume(returning: status)
                    } else {
                        continuation.resume(throwing: OpenClawError.requestFailed("Failed to fetch cron status"))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// 查询任务执行历史
    func fetchCronRuns(jobId: String, limit: Int? = nil) async throws -> [CronRunEntry] {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = CronRunsRequest(
            id: requestId,
            params: CronRunsRequest.CronRunsParams(id: jobId, limit: limit)
        )

        print("[CronRuns] 📤 Fetching runs for job: \(jobId), limit: \(limit ?? -1)")

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    // Debug: Print raw JSON
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("[CronRuns] 📥 Raw response: \(jsonString)")
                    }

                    if let response = try? JSONDecoder().decode(CronRunsResponse.self, from: data),
                       response.ok {
                        let entries = response.payload?.entries ?? []
                        print("[CronRuns] ✅ Successfully decoded \(entries.count) run entries")
                        continuation.resume(returning: entries)
                    } else {
                        do {
                            let _ = try JSONDecoder().decode(CronRunsResponse.self, from: data)
                        } catch {
                            print("[CronRuns] ❌ Decoding error: \(error)")
                        }
                        continuation.resume(throwing: OpenClawError.requestFailed("Failed to fetch cron runs"))
                    }
                case .failure(let error):
                    print("[CronRuns] ❌ Request error: \(error)")
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    print("[CronRuns] ⏱️ Timeout")
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// 添加定时任务
    func addCronJob(id: String, schedule: String, action: CronAction, enabled: Bool = true) async throws {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = CronAddRequest(
            id: requestId,
            params: CronAddRequest.CronAddParams(
                id: id,
                schedule: schedule,
                action: action,
                enabled: enabled
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(CronGenericResponse.self, from: data),
                       response.ok {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: OpenClawError.requestFailed("Failed to add cron job"))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// 更新定时任务
    func updateCronJob(id: String, patch: CronJobPatch) async throws {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = CronUpdateRequest(
            id: requestId,
            params: CronUpdateRequest.CronUpdateParams(id: id, patch: patch)
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(CronGenericResponse.self, from: data),
                       response.ok {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: OpenClawError.requestFailed("Failed to update cron job"))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// 删除定时任务
    func removeCronJob(id: String) async throws {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = CronRemoveRequest(
            id: requestId,
            params: CronRemoveRequest.CronRemoveParams(id: id)
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(CronGenericResponse.self, from: data),
                       response.ok {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: OpenClawError.requestFailed("Failed to remove cron job"))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// 手动执行定时任务
    func runCronJob(id: String, mode: String = "force") async throws {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = CronRunRequest(
            id: requestId,
            params: CronRunRequest.CronRunParams(id: id, mode: mode)
        )

        print("[CronRun] 📤 Running cron job: \(id), mode: \(mode), requestId: \(requestId)")

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let jsonString = String(data: data, encoding: .utf8) {
                        print("[CronRun] 📥 Response: \(jsonString)")
                    }

                    if let response = try? JSONDecoder().decode(CronGenericResponse.self, from: data),
                       response.ok {
                        print("[CronRun] ✅ Cron job executed successfully")
                        continuation.resume()
                    } else {
                        print("[CronRun] ❌ Failed to run cron job")
                        continuation.resume(throwing: OpenClawError.requestFailed("Failed to run cron job"))
                    }
                case .failure(let error):
                    print("[CronRun] ❌ Error: \(error)")
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    print("[CronRun] ⏱️ Timeout")
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// Fetch skills status from Gateway (skills.status API)
    func fetchSkillsStatus(agentId: String? = nil) async throws -> [Skill] {
        try await ensureGatewayConnectedForRPC()

        let requestId = UUID().uuidString
        let request = SkillsStatusRequest(
            id: requestId,
            params: SkillsStatusRequest.Params(agentId: agentId)
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(SkillsStatusResponse.self, from: data) {
                        if response.ok {
                            let skills = response.payload?.skills ?? []
                            print("[OpenClaw] Fetched \(skills.count) skill(s)")
                            continuation.resume(returning: skills)
                        } else {
                            let errorMessage = response.error?.message ?? "Failed to fetch skills"
                            continuation.resume(throwing: OpenClawError.requestFailed(errorMessage))
                        }
                    } else {
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)
            print("[OpenClaw] Sent skills.status request with id: \(requestId)")

            // Timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self = self else { return }
                if self.pendingRequests[requestId] != nil {
                    print("[OpenClaw] ⏱️ Skills request \(requestId) timed out after 10s")
                    self.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                } else {
                    print("[OpenClaw] ✅ Skills request \(requestId) completed before timeout")
                }
            }
        }
    }

    /// Update skill configuration (enable/disable, set API key, etc.)
    func updateSkill(skillKey: String, enabled: Bool? = nil, apiKey: String? = nil, env: [String: String]? = nil) async throws -> SkillUpdateResponse.Payload {
        try await ensureGatewayConnectedForRPC()

        let requestId = UUID().uuidString
        let request = SkillUpdateRequest(
            id: requestId,
            params: SkillUpdateRequest.Params(
                skillKey: skillKey,
                enabled: enabled,
                apiKey: apiKey,
                env: env
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(SkillUpdateResponse.self, from: data) {
                        if response.ok, let payload = response.payload {
                            print("[OpenClaw] ✅ Updated skill \(skillKey): enabled=\(enabled ?? false)")
                            continuation.resume(returning: payload)
                        } else {
                            let errorMsg = response.error?.message ?? "Unknown error"
                            print("[OpenClaw] ❌ Failed to update skill: \(errorMsg)")
                            continuation.resume(throwing: OpenClawError.requestFailed(errorMsg))
                        }
                    } else {
                        print("[OpenClaw] ❌ Failed to decode skill update response")
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)
            print("[OpenClaw] Sent skills.update request for \(skillKey) with id: \(requestId)")

            // Timeout
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self = self else { return }
                if self.pendingRequests[requestId] != nil {
                    print("[OpenClaw] ⏱️ Skill update request \(requestId) timed out after 10s")
                    self.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// Fetch chat history from Gateway (chat.history API)
    func fetchChatHistory(sessionKey: String, limit: Int = 200) async throws -> ChatHistoryResponse {
        let requestId = UUID().uuidString
        let request = ChatHistoryRequest(
            id: requestId,
            params: ChatHistoryRequest.HistoryParams(
                sessionKey: sessionKey,
                limit: limit
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(ChatHistoryResponse.self, from: data) {
                        if response.ok {
                            continuation.resume(returning: response)
                        } else {
                            let errorMessage = response.error?.message ?? "Unknown error"
                            continuation.resume(throwing: OpenClawError.requestFailed(errorMessage))
                        }
                    } else {
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            // Timeout after 30 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// Fetch sessions list from Gateway (sessions.list API)
    /// Returns remote sessions with their sessionKey format for sync validation
    func fetchSessionsList(limit: Int = 100, activeMinutes: Int = 10080) async throws -> SessionsListResponse {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = SessionsListRequest(
            id: requestId,
            params: SessionsListRequest.SessionsListParams(
                limit: limit,
                activeMinutes: activeMinutes,
                includePreview: nil
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(SessionsListResponse.self, from: data) {
                        if response.ok == false {
                            let errorMessage = response.error?.message ?? "sessions.list failed"
                            continuation.resume(throwing: OpenClawError.requestFailed(errorMessage))
                            return
                        }
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// Patch session config (sessions.patch API)
    /// Updates thinkingLevel for a specific sessionKey
    @discardableResult
    func patchThinkingLevel(sessionKey: String, thinkingLevel: String) async throws -> SessionsPatchResponse {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString
        let request = SessionsPatchRequest(
            id: requestId,
            params: SessionsPatchRequest.SessionsPatchParams(
                key: sessionKey,
                thinkingLevel: thinkingLevel,
                model: nil
            )
        )

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    if let response = try? JSONDecoder().decode(SessionsPatchResponse.self, from: data) {
                        continuation.resume(returning: response)
                    } else {
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            webSocketManager.send(request)

            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    /// Session sync result: contains sessionKeys that exist locally but not on server
    struct SessionSyncResult {
        let orphanedLocalSessionIds: [String]  // Local session IDs to delete
        let serverSessionKeys: [String]         // All sessionKeys from server
    }

    /// Sync local OpenClaw sessions with server for a given agent.
    /// Compares local sessions' sessionKeys against what the server knows.
    /// Returns orphaned sessions that should be deleted locally.
    func syncSessions(localSessions: [ContextGoSession]) async throws -> SessionSyncResult {
        let response = try await fetchSessionsList(limit: 200, activeMinutes: 525600) // ~1 year

        guard let serverSessions = response.sessions else {
            throw OpenClawError.decodingFailed
        }

        let serverKeys = Set(serverSessions.map { $0.key })
        print("[OpenClaw] 🔄 Session sync: server has \(serverKeys.count) sessions")

        // Find local sessions whose sessionKey doesn't exist on server
        var orphaned: [String] = []
        for local in localSessions {
            guard let localKey = local.channelMetadataDict?["sessionKey"] as? String else { continue }
            if !serverKeys.contains(localKey) {
                print("[OpenClaw] 🗑️ Orphaned session: \(local.id) (key: \(localKey))")
                orphaned.append(local.id)
            }
        }

        print("[OpenClaw] 🔄 Session sync complete: \(orphaned.count) orphaned, \(localSessions.count - orphaned.count) valid")
        return SessionSyncResult(
            orphanedLocalSessionIds: orphaned,
            serverSessionKeys: Array(serverKeys)
        )
    }

    // MARK: - Generic RPC API

    /// Send a generic RPC request (for config.get, config.patch, etc.)
    func sendRPC<T: Decodable>(method: String, params: [String: Any]? = nil) async throws -> T {
        guard isConnected else {
            throw OpenClawError.notConnected
        }

        let requestId = UUID().uuidString

        // Build RPC request manually as JSON
        var rpcRequest: [String: Any] = [
            "type": "req",
            "method": method,
            "id": requestId
        ]

        if let params = params {
            rpcRequest["params"] = params
        }

        print("[OpenClaw] 📤 Sending RPC request: \(method), id: \(requestId)")

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[requestId] = { result in
                switch result {
                case .success(let data):
                    // Try to decode the generic response
                    if let response = try? JSONDecoder().decode(GenericRPCResponse<T>.self, from: data) {
                        if response.ok, let payload = response.payload {
                            continuation.resume(returning: payload)
                        } else {
                            let errorMessage = response.error?.message ?? "RPC request failed"
                            continuation.resume(throwing: OpenClawError.requestFailed(errorMessage))
                        }
                    } else {
                        // Try to decode error details
                        do {
                            let _ = try JSONDecoder().decode(GenericRPCResponse<T>.self, from: data)
                        } catch {
                            print("[OpenClaw] ❌ Decoding error: \(error)")
                        }
                        continuation.resume(throwing: OpenClawError.decodingFailed)
                    }

                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            // Send the request as raw Data
            if let jsonData = try? JSONSerialization.data(withJSONObject: rpcRequest) {
                webSocketManager.send(data: jsonData)
            } else {
                continuation.resume(throwing: OpenClawError.requestFailed("Failed to serialize RPC request"))
                return
            }

            // Timeout after 10 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                if self?.pendingRequests[requestId] != nil {
                    self?.pendingRequests.removeValue(forKey: requestId)
                    continuation.resume(throwing: OpenClawError.timeout)
                }
            }
        }
    }

    // MARK: - Message Buffer Management

    /// Retrieve buffered messages for a specific session (returns nil if no buffer)
    func retrieveBufferedMessage(for sessionKey: String) -> BufferedMessage? {
        cleanupOldBuffers()  // Clean up expired buffers first
        return messageBuffer[sessionKey]
    }

    /// Clear buffered message for a specific session
    func clearBufferedMessage(for sessionKey: String) {
        messageBuffer.removeValue(forKey: sessionKey)
        print("📦 [OpenClaw] Cleared buffer for sessionKey: \(sessionKey)")
    }

    /// Clear all buffered messages
    func clearAllBufferedMessages() {
        messageBuffer.removeAll()
        print("📦 [OpenClaw] Cleared all message buffers")
    }

    /// Clean up buffers older than maxBufferAge
    private func cleanupOldBuffers() {
        let now = Date()
        messageBuffer = messageBuffer.filter { _, message in
            let age = now.timeIntervalSince(message.timestamp)
            return age < maxBufferAge
        }
    }

    // MARK: - Private Methods

    private func sendConnectHandshake() {
        let requestId = UUID().uuidString
        let locale = Locale.preferredLanguages.first ?? Locale.current.identifier

        // ✅ Fixed: Operator mode (UI client, not Node)
        let request = ConnectRequest(
            id: requestId,
            params: ConnectRequest.ConnectParams(
                minProtocol: 3,
                maxProtocol: 3,
                client: clientInfo,
                role: nil,         // ✅ No role for operator
                scopes: nil,       // ✅ No scopes for operator (handled by Gateway)
                caps: [],          // ✅ Empty for operator
                commands: nil,     // ✅ No commands for operator
                permissions: nil,  // ✅ No permissions for operator
                locale: locale,
                auth: ConnectRequest.ConnectParams.AuthInfo(
                    token: self.secret,  // Token from URL query parameter
                    signature: nil,
                    nonce: nil
                )
            )
        )

        pendingRequests[requestId] = { [weak self] result in
            switch result {
            case .success(let data):
                if let response = try? JSONDecoder().decode(ConnectResponse.self, from: data) {
                    DispatchQueue.main.async {
                        if response.ok == true {
                            print("[OpenClaw] ✅ Handshake successful")
                            self?.isConnected = true
                            self?.presenceInfo = response.payload?.presence
                        } else {
                            print("[OpenClaw] ❌ Handshake failed: \(response.error?.message ?? "unknown")")
                        }
                    }
                }

            case .failure(let error):
                print("[OpenClaw] ❌ Handshake error: \(error.localizedDescription)")
            }
        }

        webSocketManager.send(request)
    }

    private func handleMessage(_ data: Data) {
        let message = OpenClawMessage(from: data)

        switch message {
        case .helloResponse(let response):
            handleHelloResponse(response)

        case .connectResponse(let response):
            handleConnectResponse(response, data: data)

        case .connectChallengeEvent(let event):
            // Handle challenge event - server requires token auth, not signature
            print("[OpenClaw] 🔐 Received connect.challenge event")
            print("[OpenClaw]    Nonce: \(event.payload.nonce)")
            print("[OpenClaw]    Timestamp: \(event.payload.ts)")

            // ✅ Some servers send challenge but still expect token (not signature)
            // Send ConnectRequest with token auth using standard client info
            sendConnectHandshake()

        case .agentResponse(let response):
            handleAgentResponse(response, data: data)

        case .agentEvent(let event):
            handleAgentEvent(event)

        case .chatEvent(let event):
            handleChatEvent(event)

        case .healthResponse(let response):
            handleHealthResponse(response, data: data)

        case .healthEvent(let event):
            handleHealthEvent(event)

        case .cronEvent(let event):
            handleCronEvent(event)

        case .unknown:
            // 先检查是否有 id 字段，只有响应消息才有 id
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let type = json["type"] as? String {

                // 如果是 event 类型且没有 id，直接忽略（可能是心跳或时间戳事件）
                if type == "event" && json["id"] == nil {
                    if let payloadKeys = (json["payload"] as? [String: Any])?.keys {
                        // 只记录调试信息，不报错
                        print("[OpenClaw] 📨 Received event without id - payload keys: \(Array(payloadKeys))")
                    }
                    return
                }

                // 如果是 res 类型或有 id 字段，尝试解码为已知的响应类型
                if type == "res" || json["id"] != nil {
                    // Try to handle as generic response with id (for pending requests)
                    if let id = json["id"] as? String, let callback = pendingRequests.removeValue(forKey: id) {
                        print("[OpenClaw] ✅ Found pending request for id: \(id), executing callback")
                        callback(Result<Data, Error>.success(data))
                        return
                    }

                    // Try to handle as SkillsStatusResponse
                    if let skillsResponse = try? JSONDecoder().decode(SkillsStatusResponse.self, from: data) {
                        print("[OpenClaw] ✅ Successfully decoded as SkillsStatusResponse")
                        handleSkillsStatusResponse(skillsResponse, data: data)
                        return
                    }
                    // Try to handle as ChatHistoryResponse
                    else if let chatHistoryResponse = try? JSONDecoder().decode(ChatHistoryResponse.self, from: data) {
                        handleChatHistoryResponse(chatHistoryResponse, data: data)
                        return
                    }
                }
            }

            // 如果都不匹配，记录未知消息
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                print("[OpenClaw] ⚠️ Unknown message - type: \(json["type"] ?? "nil"), id: \(json["id"] ?? "nil")")
                if let payloadKeys = (json["payload"] as? [String: Any])?.keys {
                    print("[OpenClaw]    Payload keys: \(Array(payloadKeys))")
                }
            }

        default:
            break
        }
    }

    // MARK: - Skills Status Response Handler

    private func handleSkillsStatusResponse(_ response: SkillsStatusResponse, data: Data) {
        let id = response.id
        print("[OpenClaw] ✅ Received skills status response: \(response.payload?.skills.count ?? 0) skills")
        print("[OpenClaw] Response ID: \(id)")
        print("[OpenClaw] Pending requests count: \(pendingRequests.count)")
        print("[OpenClaw] Pending request IDs: \(pendingRequests.keys)")

        if let callback = pendingRequests.removeValue(forKey: id) {
            print("[OpenClaw] ✅ Found callback, executing...")
            callback(Result<Data, Error>.success(data))
            print("[OpenClaw] ✅ Callback executed successfully")
        } else {
            print("[OpenClaw] ⚠️ No pending request found for skills response id: \(id)")
        }
    }

    private func handleHelloResponse(_ response: HelloResponse) {
        print("[OpenClaw] ✅ Handshake successful - Protocol v\(response.protocol)")
        print("[OpenClaw] Server: \(response.server.version)")
        print("[OpenClaw] Presence entries: \(response.snapshot.presence.count)")

        // ✅ Mark handshake as completed for Protocol v3
        hasCompletedHandshake = true
        self.isConnected = true
        self.sessionDefaults = response.snapshot.sessionDefaults

        if let defaults = sessionDefaults {
            print("[OpenClaw] Session defaults - agentId: \(defaults.defaultAgentId), sessionKey: \(defaults.mainSessionKey)")
        }

        // Extract presence info from snapshot (first entry if available)
        if let firstPresence = response.snapshot.presence.first {
            // Convert to old PresenceInfo format for compatibility
            // Presence array contains connected clients/devices
            let presenceInfo = ConnectResponse.HelloPayload.PresenceInfo(
                online: true,  // If presence array is not empty, something is online
                model: firstPresence.text  // Use text field as model info if available
            )
            self.presenceInfo = presenceInfo
        }
    }

    private func handleConnectResponse(_ response: ConnectResponse, data: Data) {
        guard let id = response.id else { return }

        // ✅ Mark handshake as completed on successful ConnectResponse
        if response.ok == true {
            hasCompletedHandshake = true
            print("[OpenClaw] ✅ Handshake completed (will skip on reconnect)")
        }

        if let callback = pendingRequests.removeValue(forKey: id) {
            callback(Result<Data, Error>.success(data))
        }
    }

    private func handleAgentResponse(_ response: AgentResponse, data: Data) {
        let hintedRunId = pendingRunHints.removeValue(forKey: response.id)
        if let hintedRunId {
            forgetTerminalRun(hintedRunId)
        }

        // Verify runId is tracked (should already be tracked from sendMessage)
        if let runId = response.payload?.runId {
            forgetTerminalRun(runId)
            if let hintedRunId, hintedRunId != runId,
               let hintIndex = runQueue.firstIndex(of: hintedRunId) {
                runQueue[hintIndex] = runId
                print("[OpenClaw] 🔁 Replaced provisional runId \(hintedRunId) -> \(runId)")
            }

            if activeRunIds.contains(runId) {
                print("[OpenClaw] ✅ Confirmed runId is tracked: \(runId)")
            } else {
                // Only add to queue if this is an initial "accepted" response, not a completed one
                let status = response.payload?.status
                let summary = response.payload?.summary

                if status == "accepted" {
                    print("[OpenClaw] ⚠️ RunId not tracked (accepted), adding now: \(runId)")
                    runQueue.append(runId)  // Add to end of queue
                    notifyRunQueueChanged()  // Notify stop button state
                } else if status == "ok" && summary == "completed" {
                    // This is a completed response, don't add to queue
                    print("[OpenClaw] ℹ️ RunId not tracked but already completed: \(runId) - ignoring")
                } else {
                    print("[OpenClaw] ⚠️ RunId not tracked, status: \(status ?? "nil"), summary: \(summary ?? "nil")")
                }
            }

            var deduped: [String] = []
            for item in runQueue where !deduped.contains(item) {
                deduped.append(item)
            }
            runQueue = deduped

            DispatchQueue.main.async {
                self.onRunAccepted?(runId)
            }
        } else if let hintedRunId {
            DispatchQueue.main.async {
                self.onRunAccepted?(hintedRunId)
            }
        }

        if let callback = pendingRequests.removeValue(forKey: response.id) {
            callback(.success(data))
        }
    }

    private func handleAgentEvent(_ event: AgentEvent) {
        let runId = event.payload.runId
        let stream = event.payload.stream
        let data = event.payload.data
        let sessionKey = event.payload.sessionKey

        // Check if this is our own request (must have our runId AND not be from other channels)
        // Events with sessionKey "agent:main:main" are from Feishu/Telegram/other channels, not our iOS app
        let isMainSession = sessionKey == "agent:main:main"
        let isOurRun = activeRunIds.contains(runId) && !isMainSession

        if activeRunIds.contains(runId) {
            print("🔍 [OpenClaw] AgentEvent for tracked runId: \(runId), sessionKey: '\(sessionKey ?? "nil")', isOurRun: \(isOurRun)")
        }

        // Monitor other channels' activity (not our run, and on main session)
        if !isOurRun, isMainSession {
            if stream == "lifecycle",
               let phase = stringValue(from: data["phase"]?.value) {
                if phase == "start" {
                    // Other channel started a conversation
                    print("[OpenClaw] 🔄 Lifecycle start detected for runId: \(runId)")
                    otherChannelRuns.insert(runId)

                    // Check if we already know the channel for this runId (from earlier chat event)
                    if let channel = runIdToChannel[runId] {
                        print("[OpenClaw] ✅ Found existing channel mapping: \(channel)")
                        activeChannels.insert(channel)
                    }
                    notifyChannelActivity()
                } else if phase == "end" || phase == "error" {
                    // Other channel finished
                    print("[OpenClaw] ✅ Lifecycle end detected for runId: \(runId)")

                    // Remove the runId and its channel mapping
                    otherChannelRuns.remove(runId)
                    if let channel = runIdToChannel.removeValue(forKey: runId) {
                        print("[OpenClaw] 🗑️ Removed channel mapping: \(channel)")
                        // Remove this channel from active channels if no other runs are using it
                        let stillActive = runIdToChannel.values.contains(channel)
                        if !stillActive {
                            activeChannels.remove(channel)
                        }
                    }

                    if otherChannelRuns.isEmpty {
                        activeChannels.removeAll()
                    }
                    notifyChannelActivity()
                }
            }
        }

        // Only process our own events for streaming
        guard isOurRun else {
            return
        }

        if stream == "assistant" {
            if let thinking = stringValue(from: data["thinking"]?.value), !thinking.isEmpty {
                DispatchQueue.main.async {
                    self.onAgentThinkingDelta?(thinking)
                }
            } else if let delta = stringValue(from: data["delta"]?.value), !delta.isEmpty {
                print("🔍 [OpenClaw] Received delta: '\(delta)' (length: \(delta.count)) for runId: \(runId)")

                if self.onAgentStreamDelta != nil {
                    DispatchQueue.main.async {
                        print("🔍 [OpenClaw] Dispatching delta to callback")
                        self.onAgentStreamDelta?(delta)
                    }
                } else {
                    if let sessionKey = sessionKey {
                        print("📦 [OpenClaw] No callback - buffering delta for sessionKey: \(sessionKey)")
                        if messageBuffer[sessionKey] == nil {
                            messageBuffer[sessionKey] = BufferedMessage(
                                sessionKey: sessionKey,
                                runId: runId,
                                deltas: [],
                                timestamp: Date(),
                                isComplete: false,
                                error: nil
                            )
                        }
                        messageBuffer[sessionKey]?.deltas.append(delta)
                    } else {
                        print("⚠️ [OpenClaw] Cannot buffer - no sessionKey in event")
                    }
                }
            } else if let text = stringValue(from: data["text"]?.value), !text.isEmpty {
                if self.onAgentStreamDelta != nil {
                    DispatchQueue.main.async {
                        self.onAgentStreamDelta?(text)
                    }
                } else {
                    if let sessionKey = sessionKey {
                        if messageBuffer[sessionKey] == nil {
                            messageBuffer[sessionKey] = BufferedMessage(
                                sessionKey: sessionKey,
                                runId: runId,
                                deltas: [],
                                timestamp: Date(),
                                isComplete: false,
                                error: nil
                            )
                        }
                        messageBuffer[sessionKey]?.deltas.append(text)
                    }
                }
            }
        }

        // Tool execution stream (protocol v3: toolCallId/name/args/partialResult/result)
        if stream == "tool" {
            handleToolStream(runId: runId, data: data)
        }

        // Error stream
        if stream == "error" {
            handleErrorStream(runId: runId, data: data)
        }

        // Compaction stream (protocol v3 uses phase start/end)
        if stream == "compaction" {
            handleCompactionStream(runId: runId, data: data)
        }

        // Lifecycle stream
        if stream == "lifecycle",
           let phase = stringValue(from: data["phase"]?.value) {
            if phase == "start" {
                forgetTerminalRun(runId)
                DispatchQueue.main.async {
                    self.onLifecycleStart?(runId)
                }
            } else if phase == "end" {
                print("[OpenClaw] 📍 Received phase=end for runId: \(runId)")
                let isFirstTerminal = markRunTerminalIfNeeded(runId)
                removeRunTracking(runId, reason: "lifecycle end")

                if let sessionKey = sessionKey, messageBuffer[sessionKey] != nil {
                    messageBuffer[sessionKey]?.isComplete = true
                    print("📦 [OpenClaw] Marked buffered message complete for sessionKey: \(sessionKey)")
                }

                guard isFirstTerminal else {
                    print("[OpenClaw] ↪️ Duplicate lifecycle end ignored for runId: \(runId)")
                    return
                }

                DispatchQueue.main.async {
                    self.onLifecycleEnd?(runId)
                    self.onAgentComplete?()
                }
            } else if phase == "error" {
                let isFirstTerminal = markRunTerminalIfNeeded(runId)
                removeRunTracking(runId, reason: "lifecycle error")
                let errorMessage = stringValue(from: data["error"]?.value) ?? "Agent execution failed"

                if let sessionKey = sessionKey, messageBuffer[sessionKey] != nil {
                    messageBuffer[sessionKey]?.error = errorMessage
                    messageBuffer[sessionKey]?.isComplete = true
                    print("📦 [OpenClaw] Marked buffered message error for sessionKey: \(sessionKey)")
                }

                guard isFirstTerminal else {
                    print("[OpenClaw] ↪️ Duplicate lifecycle error ignored for runId: \(runId)")
                    return
                }

                DispatchQueue.main.async {
                    self.onLifecycleError?(runId, errorMessage)
                    self.onAgentError?(errorMessage)
                }
            }
        }
    }

    private func handleHealthResponse(_ response: HealthResponse, data: Data) {
        if let callback = pendingRequests.removeValue(forKey: response.id) {
            callback(.success(data))
        }
    }

    private func handleChatHistoryResponse(_ response: ChatHistoryResponse, data: Data) {
        print("[OpenClaw] 📜 Received chat.history response")
        if let callback = pendingRequests.removeValue(forKey: response.id) {
            callback(.success(data))
        }
    }

    private func handleHealthEvent(_ event: HealthEvent) {
        print("[OpenClaw] 💓 Health event - ok: \(event.payload.ok)")

        // Save channel labels mapping (e.g., {"feishu": "Feishu", "telegram": "Telegram"})
        if let labels = event.payload.channelLabels {
            channelLabels = labels
            print("[OpenClaw] 📋 Channel labels: \(labels)")
        }

        // ✅ Use channelOrder (array) instead of channels
        // channelOrder contains the list of active channel IDs
        if let channelOrder = event.payload.channelOrder, !channelOrder.isEmpty {
            // Store channel IDs directly - localization happens in UI layer
            activeChannels = Set(channelOrder)
            print("[OpenClaw] ✅ Updated active channels from channelOrder: \(activeChannels)")

            // Notify UI of channel activity
            notifyChannelActivity()
        } else {
            // No active channels
            if !activeChannels.isEmpty {
                print("[OpenClaw] 🔄 Clearing active channels")
                activeChannels.removeAll()
                notifyChannelActivity()
            }
        }
    }

    private func handleCronEvent(_ event: CronEvent) {
        let payload = event.payload
        print("[OpenClaw] ⏰ Cron event: \(payload.action) for job \(payload.jobId)")

        if payload.action == "finished", let summary = payload.summary {
            print("[OpenClaw] 📝 Cron result: \(summary.prefix(100))")
        }

        // Notify listeners (e.g., ChatViewModel can show a toast)
        DispatchQueue.main.async {
            self.onCronEvent?(event)
        }
    }

    private func handleChatEvent(_ event: ChatEvent) {
        let runId = event.payload.runId
        let state = event.payload.state
        let sessionKey = event.payload.sessionKey
        let isKnownRun = activeRunIds.contains(runId) || terminalRunIds.contains(runId)
        let isOurRun = isKnownRun && sessionKey != "agent:main:main"

        if isOurRun {
            let extracted = extractTextAndThinking(from: event.payload.message)
            let stateEvent = ChatStateEvent(
                runId: runId,
                sessionKey: sessionKey,
                state: state,
                text: extracted.text,
                thinking: extracted.thinking,
                stopReason: event.payload.stopReason,
                errorMessage: event.payload.errorMessage ?? event.payload.error?.message
            )

            DispatchQueue.main.async {
                self.onChatStateEvent?(stateEvent)
            }

            if state == "aborted" {
                let isFirstTerminal = markRunTerminalIfNeeded(runId)
                removeRunTracking(runId, reason: "chat aborted")
                let reason = event.payload.stopReason ?? "已停止"
                guard isFirstTerminal else {
                    print("[OpenClaw] ↪️ Duplicate chat aborted ignored for runId: \(runId)")
                    return
                }
                DispatchQueue.main.async {
                    self.onLifecycleError?(runId, reason)
                    self.onAgentComplete?()
                }
            } else if state == "error" {
                let isFirstTerminal = markRunTerminalIfNeeded(runId)
                removeRunTracking(runId, reason: "chat error")
                let err = event.payload.errorMessage
                    ?? event.payload.error?.message
                    ?? "Agent execution failed"
                guard isFirstTerminal else {
                    print("[OpenClaw] ↪️ Duplicate chat error ignored for runId: \(runId)")
                    return
                }
                DispatchQueue.main.async {
                    self.onLifecycleError?(runId, err)
                    self.onAgentError?(err)
                }
            } else if state == "final" {
                let isFirstTerminal = markRunTerminalIfNeeded(runId)
                removeRunTracking(runId, reason: "chat final")
                guard isFirstTerminal else {
                    print("[OpenClaw] ↪️ Duplicate chat final ignored for runId: \(runId)")
                    return
                }
                DispatchQueue.main.async {
                    self.onLifecycleEnd?(runId)
                    self.onAgentComplete?()
                }
            }
            return
        }

        // Only track main session (not our contextgo session)
        guard sessionKey == "agent:main:main", !activeRunIds.contains(runId) else {
            return
        }

        print("[OpenClaw] 📨 Chat event - runId: \(runId), state: \(state), role: \(event.payload.message?.role ?? "nil")")

        // Extract channel from user message content
        if let message = event.payload.message,
           message.role == "user",
           let firstContent = message.content.first,
           let text = firstContent.text {
            print("[OpenClaw] 👤 User message text: \(text.prefix(100))")
            if let channel = extractChannelFromMessage(text) {
                print("[OpenClaw] ✅ Detected channel: \(channel) for runId: \(runId)")
                // Store channel mapping for this runId
                runIdToChannel[runId] = channel
                activeChannels.insert(channel)
                notifyChannelActivity()
            } else {
                print("[OpenClaw] ⚠️ No channel pattern found in user message")
            }
        }

        // Clean up on completion
        if state == "final" || state == "error" {
            // We don't know which channel completed, so we just notify
            // The channel will be removed when lifecycle end is detected
        }
    }

    private func extractChannelFromMessage(_ text: String) -> String? {
        // Message format: [Feishu ...] or [Telegram ...] or [Discord ...] etc
        let pattern = "^\\[([A-Za-z]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let channelRange = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let channel = String(text[channelRange])
        return channel.lowercased()
    }

    private func notifyChannelActivity() {
        // If there are active runs but no identified channels, show generic "other"
        let isActive = !otherChannelRuns.isEmpty
        DispatchQueue.main.async {
            self.onOtherChannelActivity?(self.activeChannels, isActive)
        }
    }

    private func notifyRunQueueChanged() {
        let hasActiveRuns = !runQueue.isEmpty
        print("[OpenClaw] 🛑 RunQueue state: \(runQueue.count) active runs, hasActiveRuns=\(hasActiveRuns)")
        print("[OpenClaw] 🛑 RunQueue IDs: \(runQueue)")
        DispatchQueue.main.async {
            self.onRunQueueChanged?(hasActiveRuns)
        }
    }

    // MARK: - Stream Handlers

    private func removeRunTracking(_ runId: String, reason: String) {
        if let index = runQueue.firstIndex(of: runId) {
            runQueue.remove(at: index)
            notifyRunQueueChanged()
            print("[OpenClaw] Removed runId from queue (\(reason)): \(runId), remaining: \(runQueue.count)")
        }
    }

    private func markRunTerminalIfNeeded(_ runId: String) -> Bool {
        guard !runId.isEmpty else { return false }
        if terminalRunIds.contains(runId) {
            return false
        }
        terminalRunIds.insert(runId)
        terminalRunOrder.append(runId)

        if terminalRunOrder.count > terminalRunHistoryLimit {
            let overflow = terminalRunOrder.count - terminalRunHistoryLimit
            let expired = terminalRunOrder.prefix(overflow)
            terminalRunOrder.removeFirst(overflow)
            for runId in expired {
                terminalRunIds.remove(runId)
            }
        }

        return true
    }

    private func forgetTerminalRun(_ runId: String) {
        guard !runId.isEmpty else { return }
        guard terminalRunIds.remove(runId) != nil else { return }
        terminalRunOrder.removeAll { $0 == runId }
    }

    private func stringValue(from value: Any?) -> String? {
        guard let value else { return nil }
        if let str = value as? String {
            return str
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let dict = value as? [String: Any] {
            if let text = dict["text"] as? String {
                return text
            }
            if let thinking = dict["thinking"] as? String {
                return thinking
            }
            if let content = dict["content"] as? [[String: Any]] {
                let joined = content.compactMap { item in
                    guard let type = item["type"] as? String else { return nil }
                    if type == "thinking" {
                        return (item["thinking"] as? String) ?? (item["text"] as? String)
                    }
                    guard type == "text" else { return nil }
                    return (item["text"] as? String) ?? (item["value"] as? String)
                }.joined(separator: "\n")
                return joined.isEmpty ? nil : joined
            }
            if let json = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
               let text = String(data: json, encoding: .utf8) {
                return text
            }
        }
        if let array = value as? [Any],
           let json = try? JSONSerialization.data(withJSONObject: array, options: [.prettyPrinted]),
           let text = String(data: json, encoding: .utf8) {
            return text
        }
        return String(describing: value)
    }

    private func intValue(from value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue
        }
        if let doubleValue = value as? Double {
            return Int(doubleValue)
        }
        if let stringValue = value as? String {
            return Int(stringValue)
        }
        return nil
    }

    private func extractTextAndThinking(from message: ChatEvent.ChatEventPayload.Message?) -> (text: String?, thinking: String?) {
        guard let message else { return (nil, nil) }

        let textParts = message.content.compactMap { item -> String? in
            let type = item.type.lowercased()
            guard (type == "text" || type.isEmpty), let text = item.text, !text.isEmpty else {
                return nil
            }
            return text
        }
        let thinkingParts = message.content.compactMap { item -> String? in
            let type = item.type.lowercased()
            guard type == "thinking", let text = item.text, !text.isEmpty else {
                return nil
            }
            return text
        }

        let joinedText = textParts.isEmpty ? nil : textParts.joined(separator: "\n")
        let directThinking = thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n")

        if let joinedText {
            let split = splitThinkingTaggedText(joinedText)
            let resolvedThinking = directThinking ?? split.thinking
            return (split.text, resolvedThinking)
        }

        return (joinedText, directThinking)
    }

    private func splitThinkingTaggedText(_ text: String) -> (text: String?, thinking: String?) {
        let pattern = "<\\s*think(?:ing)?\\s*>([\\s\\S]*?)<\\s*/\\s*think(?:ing)?\\s*>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? nil : trimmed, nil)
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: fullRange)
        guard !matches.isEmpty else {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (trimmed.isEmpty ? nil : trimmed, nil)
        }

        let thinkingParts = matches.compactMap { match -> String? in
            guard let range = Range(match.range(at: 1), in: text) else { return nil }
            let part = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            return part.isEmpty ? nil : part
        }

        let stripped = regex
            .stringByReplacingMatches(in: text, options: [], range: fullRange, withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (
            stripped.isEmpty ? nil : stripped,
            thinkingParts.isEmpty ? nil : thinkingParts.joined(separator: "\n")
        )
    }

    /// Handle tool execution stream events
    private func handleToolStream(runId: String, data: [String: AnyCodable]) {
        guard let phase = stringValue(from: data["phase"]?.value) else {
            print("⚠️ [OpenClaw] Tool event missing phase")
            return
        }

        // Protocol v3: toolCallId/name/args/partialResult/result
        let toolId = stringValue(from: data["toolCallId"]?.value)
            ?? stringValue(from: data["toolId"]?.value)
        let toolName = stringValue(from: data["name"]?.value)
            ?? stringValue(from: data["toolName"]?.value)
            ?? "tool"

        guard let resolvedToolId = toolId, !resolvedToolId.isEmpty else {
            print("⚠️ [OpenClaw] Tool event missing toolCallId/toolId")
            return
        }

        print("🔧 [OpenClaw] Tool event - phase: \(phase), runId: \(runId), toolId: \(resolvedToolId), toolName: \(toolName)")

        DispatchQueue.main.async {
            switch phase {
            case "start":
                let input = self.stringValue(from: data["args"]?.value)
                    ?? self.stringValue(from: data["input"]?.value)
                self.onToolExecutionStart?(runId, resolvedToolId, toolName, input)

            case "update":
                let partialOutput = self.stringValue(from: data["partialResult"]?.value)
                    ?? self.stringValue(from: data["partialOutput"]?.value)
                if let partialOutput, !partialOutput.isEmpty {
                    self.onToolExecutionUpdate?(runId, resolvedToolId, partialOutput)
                }

            case "result":
                let output = self.stringValue(from: data["result"]?.value)
                    ?? self.stringValue(from: data["output"]?.value)
                let error = self.stringValue(from: data["error"]?.value)
                self.onToolExecutionResult?(runId, resolvedToolId, output, error)

            default:
                print("⚠️ [OpenClaw] Unknown tool phase: \(phase)")
            }
        }
    }

    /// Handle error stream events
    private func handleErrorStream(runId: String, data: [String: AnyCodable]) {
        let error = stringValue(from: data["error"]?.value) ?? "Agent execution failed"
        let code = stringValue(from: data["code"]?.value)
        let details = stringValue(from: data["details"]?.value)

        print("❌ [OpenClaw] Error stream - runId: \(runId), error: \(error), code: \(code ?? "nil"), details: \(details ?? "nil")")

        let isFirstTerminal = markRunTerminalIfNeeded(runId)
        removeRunTracking(runId, reason: "stream error")

        guard isFirstTerminal else {
            print("[OpenClaw] ↪️ Duplicate stream error ignored for runId: \(runId)")
            return
        }

        DispatchQueue.main.async {
            self.onLifecycleError?(runId, error)
            self.onAgentError?(error)
        }
    }

    /// Handle memory compaction stream events
    private func handleCompactionStream(runId: String, data: [String: AnyCodable]) {
        let phase = stringValue(from: data["phase"]?.value) ?? "unknown"
        let messageCount = intValue(from: data["messageCount"]?.value)
        let compactionEvent = CompactionEvent(runId: runId, phase: phase, messageCount: messageCount)

        print("🗜️ [OpenClaw] Memory compaction - runId: \(runId), phase: \(phase), messageCount: \(messageCount?.description ?? "nil")")

        DispatchQueue.main.async {
            self.onCompactionEvent?(compactionEvent)
            if let messageCount {
                self.onMemoryCompaction?(messageCount)
            }
        }
    }

    private func ensureGatewayConnectedForRPC(timeout: TimeInterval = 5.0) async throws {
        if isConnected { return }

        // If currently disconnected/error, actively trigger a reconnect.
        switch connectionState {
        case .disconnected, .error:
            webSocketManager.connect()
        case .connecting, .connected:
            break
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !isConnected && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        guard isConnected else {
            throw OpenClawError.notConnected
        }
    }
}

// MARK: - Errors

enum OpenClawError: LocalizedError {
    case notConnected
    case requestFailed(String)
    case decodingFailed
    case timeout

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to ClawdBot"
        case .requestFailed(let message):
            return "Request failed: \(message)"
        case .decodingFailed:
            return "Failed to decode response"
        case .timeout:
            return "Request timed out"
        }
    }
}
