//
//  RelayClient.swift
//  contextgo
//
//  Native CLI relay protocol client (sessions/messages/machines + encrypted RPC)
//

import Foundation
import Combine

@MainActor
class RelayClient: ObservableObject {
    // MARK: - Published Properties
    @Published private(set) var isConnected: Bool = false
    @Published private(set) var connectionState: ConnectionState = .disconnected

    // MARK: - Configuration
    private let serverURL: URL
    private let token: String
    private let botId: String
    private let masterSecret: Data?
    private let encryption: CLIRelayEncryption?
    private let crypto = NaClCrypto.shared

    var ownerAgentId: String { botId }

    func hasSameConfiguration(serverURL: URL, token: String, masterSecret: Data?) -> Bool {
        guard self.serverURL.absoluteString == serverURL.absoluteString else { return false }
        guard self.token == token else { return false }
        return self.masterSecret == masterSecret
    }

    // MARK: - WebSocket
    private var webSocket: URLSessionWebSocketTask?
    private var pingTimer: Timer?
    private var reconnectTimer: Timer?
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 10
    private var engineIOSid: String?
    private var pingInterval: TimeInterval = 15.0
    private var pingTimeout: TimeInterval = 45.0
    private var nextRPCRequestId: Int = 1
    private var pendingRPCResponses: [Int: PendingRPCResponse] = [:]

    // MARK: - Runtime Cache
    private var sessionUsesDataKey: [String: Bool] = [:]
    private var machineUsesDataKey: [String: Bool] = [:]
    private var sessionLastSeq: [String: Int] = [:]
    private var supportsV2MessagesAPI: Bool?

    // MARK: - Callbacks
    var onNewMessage: ((String, [String: Any]) -> Void)?
    var onSessionActivity: ((String, ActivityState) -> Void)?

    // MARK: - Combine Subjects
    let newMessageSubject = PassthroughSubject<(sessionId: String, messageData: [String: Any]), Never>()
    let sessionActivitySubject = PassthroughSubject<(sessionId: String, state: ActivityState), Never>()

    // MARK: - Models

    struct DecodedMessageBatch {
        let messages: [[String: Any]]
        let nextSinceSeq: Int
        let hasMore: Bool
    }

    struct RemoteMachine: Identifiable {
        let id: String
        let displayName: String
        let host: String
        let homeDir: String
        let runtimeType: String?
        let daemonPid: Int?
        let daemonStatus: String?
        let active: Bool
        let activeAt: Date
    }

    enum SpawnSessionResult {
        case success(sessionId: String)
        case requestDirectoryApproval(directory: String)
        case error(message: String)
    }

    struct SessionActionResult {
        let success: Bool
        let message: String
    }

    enum ActivityState: Equatable {
        case thinking
        case idle
        case waitingForPermission
    }

    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case error(String)
    }

    private enum RPCError: LocalizedError {
        case notConnected
        case encodeFailed
        case timeout(method: String)
        case invalidResponse
        case serverError(String)
        case disconnected

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "WebSocket not connected"
            case .encodeFailed:
                return "Failed to encode RPC payload"
            case .timeout(let method):
                return "RPC call timed out: \(method)"
            case .invalidResponse:
                return "Invalid RPC response"
            case .serverError(let message):
                return message
            case .disconnected:
                return "Connection lost while waiting for RPC response"
            }
        }
    }

    private struct PendingRPCResponse {
        let continuation: CheckedContinuation<Any, Error>
        let timeoutTask: Task<Void, Never>
    }

    // MARK: - Initialization

    init(serverURL: URL, token: String, botId: String, masterSecret: Data? = nil) {
        self.serverURL = serverURL
        self.token = token
        self.botId = botId

        if let masterSecret, masterSecret.count == 32 {
            self.masterSecret = masterSecret
            self.encryption = CLIRelayEncryption(secret: masterSecret)
        } else {
            self.masterSecret = nil
            self.encryption = nil
        }
    }

    // MARK: - Connection Management

    func connect() {
        guard connectionState != .connecting && connectionState != .connected else {
            return
        }

        connectionState = .connecting
        reconnectAttempts = 0
        connectWebSocket()
    }

    private func connectWebSocket() {
        stopReconnectTimer()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil

        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)!
        components.path = "/v1/updates/"
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket")
        ]

        if components.scheme == "http" {
            components.scheme = "ws"
        } else if components.scheme == "https" {
            components.scheme = "wss"
        }

        guard let wsURL = components.url else {
            connectionState = .error("Invalid WebSocket URL")
            return
        }

        var request = URLRequest(url: wsURL)
        request.timeoutInterval = 20

        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()

        receiveMessage()
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        stopPingTimer()
        stopReconnectTimer()
        failPendingRPCResponses(with: RPCError.disconnected)
        connectionState = .disconnected
        isConnected = false
        engineIOSid = nil
    }

    // MARK: - Socket.IO Protocol

    private func parseSocketIOMessage(_ text: String) {
        if text.hasPrefix("0") && text.contains("sid") {
            handleEngineIOOpen(text)
        } else if text == "2" {
            send(text: "3")
        } else if text.hasPrefix("40") {
            handleSocketIOConnect(text)
        } else if text.hasPrefix("41") {
            handleConnectionLost()
        } else if text.hasPrefix("42") {
            let jsonString = String(text.dropFirst(2))
            parseEvent(jsonString)
        } else if text.hasPrefix("43") {
            handleRPCAck(text)
        } else if text.hasPrefix("44") {
            connectionState = .error("Socket.IO connect error")
            handleConnectionLost()
        }
    }

    private func handleRPCAck(_ text: String) {
        let payload = String(text.dropFirst(2))
        let idPrefix = payload.prefix { $0.isNumber }

        guard !idPrefix.isEmpty,
              let requestId = Int(idPrefix) else {
            return
        }

        let jsonPayload = String(payload.dropFirst(idPrefix.count))

        guard let pending = pendingRPCResponses.removeValue(forKey: requestId) else {
            return
        }

        pending.timeoutTask.cancel()

        guard let jsonData = jsonPayload.data(using: .utf8),
              let args = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
              let ackBody = args.first else {
            pending.continuation.resume(throwing: RPCError.invalidResponse)
            return
        }

        if let response = ackBody as? [String: Any],
           let ok = response["ok"] as? Bool {
            if !ok {
                let message = extractRPCErrorMessage(response["error"]) ?? "RPC call failed"
                pending.continuation.resume(throwing: RPCError.serverError(message))
                return
            }

            if let result = response["result"] {
                if result is NSNull {
                    pending.continuation.resume(returning: [String: Any]())
                } else {
                    pending.continuation.resume(returning: result)
                }
            } else {
                pending.continuation.resume(returning: [String: Any]())
            }
            return
        }

        pending.continuation.resume(returning: ackBody)
    }

    private func extractRPCErrorMessage(_ value: Any?) -> String? {
        if let message = value as? String, !message.isEmpty {
            return message
        }
        if let dict = value as? [String: Any] {
            if let message = dict["message"] as? String, !message.isEmpty {
                return message
            }
            if let code = dict["code"] as? String {
                return code
            }
        }
        return nil
    }

    private func handleEngineIOOpen(_ text: String) {
        guard let jsonStart = text.firstIndex(of: "{"),
              let jsonData = String(text[jsonStart...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let sid = json["sid"] as? String else {
            return
        }

        engineIOSid = sid

        if let interval = json["pingInterval"] as? Double {
            pingInterval = interval / 1000.0
        }
        if let timeout = json["pingTimeout"] as? Double {
            pingTimeout = timeout / 1000.0
        }

        let auth: [String: Any] = [
            "token": token,
            "clientType": "user-scoped"
        ]

        if let authData = try? JSONSerialization.data(withJSONObject: auth),
           let authJSON = String(data: authData, encoding: .utf8) {
            let connectPacket = "40" + authJSON
            send(text: connectPacket)
        }
    }

    private func handleSocketIOConnect(_ text: String) {
        isConnected = true
        connectionState = .connected
        reconnectAttempts = 0
        startPingTimer()
    }

    private func parseEvent(_ jsonString: String) {
        guard let jsonData = jsonString.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: jsonData) as? [Any],
              array.count >= 2,
              let eventName = array[0] as? String else {
            return
        }

        switch eventName {
        case "update":
            handleUpdate(array[1])
        case "ephemeral":
            handleEphemeral(array[1])
        default:
            break
        }
    }

    // MARK: - Event Handlers

    private func handleUpdate(_ data: Any) {
        guard let dict = data as? [String: Any] else { return }

        let body = dict["body"] as? [String: Any] ?? dict
        guard let type = body["t"] as? String ?? body["type"] as? String else {
            return
        }

        switch type {
        case "new-message":
            guard let sessionId = body["sid"] as? String ?? body["sessionId"] as? String ?? body["id"] as? String,
                  let rawMessage = body["message"] as? [String: Any] ?? dict["message"] as? [String: Any],
                  let decoded = decodeIncomingMessage(rawMessage, sessionId: sessionId) else {
                return
            }

            onNewMessage?(sessionId, decoded)
            newMessageSubject.send((sessionId: sessionId, messageData: decoded))

        case "delete-session":
            if let sessionId = body["sid"] as? String ?? body["sessionId"] as? String ?? body["id"] as? String {
                NotificationCenter.default.post(
                    name: NSNotification.Name("CLISessionDeleted"),
                    object: nil,
                    userInfo: ["sessionId": sessionId, "botId": botId]
                )
            }

        case "update-session":
            handleSessionUpdate(body)

        default:
            break
        }
    }

    private func handleSessionUpdate(_ body: [String: Any]) {
        guard let sessionId = body["sid"] as? String ?? body["sessionId"] as? String ?? body["id"] as? String else {
            return
        }

        let metadataContainer = body["metadata"] as? [String: Any]
        let agentStateContainer = body["agentState"] as? [String: Any]
        let metadataEncrypted = metadataContainer?["value"]
        let agentStateEncrypted = agentStateContainer?["value"]

        var preferredMode = sessionUsesDataKey[sessionId] ?? true
        var metadataObject = decodeEncryptedObject(
            encrypted: metadataEncrypted,
            resourceId: sessionId,
            prefersDataKey: preferredMode
        ) as? [String: Any]
        var agentStateObject = decodeEncryptedObject(
            encrypted: agentStateEncrypted,
            resourceId: sessionId,
            prefersDataKey: preferredMode
        ) as? [String: Any]

        if metadataObject == nil && agentStateObject == nil {
            let fallbackMode = !preferredMode
            let fallbackMetadata = decodeEncryptedObject(
                encrypted: metadataEncrypted,
                resourceId: sessionId,
                prefersDataKey: fallbackMode
            ) as? [String: Any]
            let fallbackAgentState = decodeEncryptedObject(
                encrypted: agentStateEncrypted,
                resourceId: sessionId,
                prefersDataKey: fallbackMode
            ) as? [String: Any]

            if fallbackMetadata != nil || fallbackAgentState != nil {
                preferredMode = fallbackMode
                metadataObject = fallbackMetadata
                agentStateObject = fallbackAgentState
            }
        }
        sessionUsesDataKey[sessionId] = preferredMode

        let metadata = decodeMetadata(from: metadataObject)
        let agentState = decodeAgentState(from: agentStateObject)
        let metadataVersion = parseInt(metadataContainer?["version"])
        let agentStateVersion = parseInt(agentStateContainer?["version"])

        let hasAgentStateUpdate = agentState != nil || agentStateVersion != nil

        var userInfo: [String: Any] = [
            "sessionId": sessionId,
            "botId": botId,
            "hasMetadataUpdate": metadata != nil,
            "hasAgentStateUpdate": hasAgentStateUpdate
        ]

        if let metadata {
            userInfo["metadata"] = metadataJSON(metadata)
            userInfo["displayName"] = metadata.customTitle ?? metadata.summary?.text ?? metadata.pathBasename
        }
        if let metadataVersion {
            userInfo["metadataVersion"] = metadataVersion
        }
        if let agentState {
            userInfo["agentStateStatus"] = agentState.status.rawValue
        }
        if let agentStateVersion {
            userInfo["agentStateVersion"] = agentStateVersion
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("CLISessionUpdated"),
            object: nil,
            userInfo: userInfo
        )

        if let metadata {
            Task {
                await persistSessionMetadataPatch(
                    sessionId: sessionId,
                    metadata: metadata,
                    metadataVersion: metadataVersion
                )
            }
        }
    }

    private func persistSessionMetadataPatch(
        sessionId: String,
        metadata: CLISession.Metadata,
        metadataVersion: Int?
    ) async {
        let repository = LocalSessionRepository.shared
        do {
            let sessions = try await repository.getAllSessions(agentId: botId)
            guard var local = sessions.first(where: { ($0.cliSessionId ?? $0.id) == sessionId }) else {
                return
            }

            local.title = metadata.customTitle ?? metadata.summary?.text ?? metadata.pathBasename
            if let summaryText = metadata.summary?.text, !summaryText.isEmpty {
                local.preview = summaryText
            }
            local.updatedAt = Date()
            local.lastSyncAt = Date()

            var channelMetadata = local.channelMetadataDict ?? [:]
            channelMetadata["cliSessionId"] = sessionId
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
            if let metadataVersion {
                channelMetadata["metadataVersion"] = metadataVersion
            }

            if let summary = metadata.summary {
                channelMetadata["summary"] = [
                    "text": summary.text,
                    "updatedAt": Int64(summary.updatedAt.timeIntervalSince1970 * 1000)
                ]
            }

            if let rawData = try? JSONSerialization.data(withJSONObject: metadataJSON(metadata)),
               let rawJSON = String(data: rawData, encoding: .utf8) {
                channelMetadata["rawJSON"] = rawJSON
            }

            local.setChannelMetadata(channelMetadata)
            try await repository.updateSession(local, notifyCloud: false)
        } catch {
            print("⚠️ [RelayClient] Failed to persist session metadata patch: \(error)")
        }
    }

    private func handleEphemeral(_ data: Any) {
        guard let dict = data as? [String: Any] else { return }

        if let type = dict["type"] as? String, type == "activity",
           let sessionId = dict["id"] as? String {
            let thinking = dict["thinking"] as? Bool ?? false
            publishSessionActivity(sessionId: sessionId, state: thinking ? .thinking : .idle)
            return
        }

        let body = dict["body"] as? [String: Any] ?? dict
        guard let type = body["t"] as? String ?? body["type"] as? String else { return }

        switch type {
        case "session-activity":
            if let sessionId = body["sessionId"] as? String,
               let status = body["status"] as? String {
                let activityState: ActivityState
                switch status {
                case "thinking":
                    activityState = .thinking
                case "waiting_for_permission":
                    activityState = .waitingForPermission
                default:
                    activityState = .idle
                }
                publishSessionActivity(sessionId: sessionId, state: activityState)
            }
        default:
            break
        }
    }

    private func publishSessionActivity(sessionId: String, state: ActivityState) {
        onSessionActivity?(sessionId, state)
        sessionActivitySubject.send((sessionId: sessionId, state: state))
    }

    // MARK: - Public RPC API

    func sendRPC(method: String, params: [String: Any], to sessionId: String) async throws {
        _ = try await sessionRPC(method: method, params: params, to: sessionId)
    }

    func getRuntimeConfig(for sessionId: String, timeout: TimeInterval = 12.0) async throws -> [String: Any] {
        let value = try await sessionRPC(method: "getRuntimeConfig", params: [:], to: sessionId, timeout: timeout)
        return value as? [String: Any] ?? [:]
    }

    func setRuntimeConfig(
        for sessionId: String,
        mode: String? = nil,
        permissionMode: String? = nil,
        reasoningEffort: String? = nil,
        modeId: String? = nil,
        modelId: String? = nil,
        variant: String? = nil,
        timeout: TimeInterval = 20.0
    ) async throws -> [String: Any] {
        var params: [String: Any] = [:]
        if let mode,
           !mode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["mode"] = mode
        }
        if let permissionMode,
           !permissionMode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["permissionMode"] = permissionMode
        }
        if let reasoningEffort {
            let normalized = reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
            params["reasoningEffort"] = normalized
        }
        if let modeId,
           !modeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["modeId"] = modeId
        }
        if let modelId,
           !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            params["modelId"] = modelId
        }
        if let variant {
            let normalized = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            params["variant"] = normalized
        }
        let value = try await sessionRPC(
            method: "setRuntimeConfig",
            params: params,
            to: sessionId,
            timeout: timeout
        )
        return value as? [String: Any] ?? [:]
    }

    func listSessionSkills(
        for sessionId: String,
        spaceUri: String? = nil,
        timeout: TimeInterval = 20.0
    ) async throws -> [CLISession.Metadata.Runtime.Skill] {
        var params: [String: Any] = [:]
        if let spaceUri {
            let normalized = spaceUri.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty {
                params["spaceUri"] = normalized
            }
        }

        let value = try await sessionRPC(
            method: "listSessionSkills",
            params: params,
            to: sessionId,
            timeout: timeout
        )

        if let dict = value as? [String: Any],
           let skills = parseRuntimeSkills(dict["skills"]) {
            return skills
        }
        if let direct = parseRuntimeSkills(value) {
            return direct
        }
        return []
    }

    func sessionRPC(
        method: String,
        params: [String: Any],
        to sessionId: String,
        timeout: TimeInterval = 12.0
    ) async throws -> Any {
        let prefersDataKey = try await resolveSessionPrefersDataKey(sessionId: sessionId)
        let encodedParams = try encodeRPCParams(params, resourceId: sessionId, prefersDataKey: prefersDataKey)
        let raw = try await sendRPCWithResponseRaw(
            fullMethod: "\(sessionId):\(method)",
            params: encodedParams,
            timeout: timeout
        )
        return try decodeRPCResult(raw, resourceId: sessionId, prefersDataKey: prefersDataKey)
    }

    func sessionAbort(sessionId: String, timeout: TimeInterval = 20.0) async throws {
        let reason = """
        The user asked to stop the current execution. Stop what you are doing and wait for the next instruction.
        """
        do {
            _ = try await sessionRPC(
                method: "abort",
                params: ["reason": reason],
                to: sessionId,
                timeout: timeout
            )
        } catch RPCError.invalidResponse {
            // Some CLI handlers are fire-and-forget and may ack with payloads that
            // cannot be decoded by older clients. Treat as delivered best-effort.
            return
        }
    }

    func sessionAllow(
        sessionId: String,
        permissionId: String,
        mode: String? = nil,
        allowedTools: [String]? = nil,
        decision: String? = nil,
        timeout: TimeInterval = 20.0
    ) async throws {
        var params: [String: Any] = [
            "id": permissionId,
            "approved": true
        ]
        if let mode, !mode.isEmpty {
            params["mode"] = mode
        }
        if let allowedTools, !allowedTools.isEmpty {
            params["allowTools"] = allowedTools
        }
        if let decision, !decision.isEmpty {
            params["decision"] = decision
        }
        do {
            _ = try await sessionRPC(
                method: "permission",
                params: params,
                to: sessionId,
                timeout: timeout
            )
        } catch RPCError.invalidResponse {
            // Backward-compatibility: older servers may ack `void` handlers with
            // payloads that decode as invalid response on iOS. Permission action
            // itself is already delivered, so we ignore this decode error.
            return
        }
    }

    func sessionDeny(
        sessionId: String,
        permissionId: String,
        mode: String? = nil,
        allowedTools: [String]? = nil,
        decision: String? = nil,
        timeout: TimeInterval = 20.0
    ) async throws {
        var params: [String: Any] = [
            "id": permissionId,
            "approved": false
        ]
        if let mode, !mode.isEmpty {
            params["mode"] = mode
        }
        if let allowedTools, !allowedTools.isEmpty {
            params["allowTools"] = allowedTools
        }
        if let decision, !decision.isEmpty {
            params["decision"] = decision
        }
        do {
            _ = try await sessionRPC(
                method: "permission",
                params: params,
                to: sessionId,
                timeout: timeout
            )
        } catch RPCError.invalidResponse {
            // Same compatibility behavior as `sessionAllow`.
            return
        }
    }

    func machineRPC(
        machineId: String,
        method: String,
        params: [String: Any],
        timeout: TimeInterval = 20.0
    ) async throws -> Any {
        let prefersDataKey = machineUsesDataKey[machineId] ?? true
        let encodedParams = try encodeRPCParams(params, resourceId: machineId, prefersDataKey: prefersDataKey)
        let raw = try await sendRPCWithResponseRaw(
            fullMethod: "\(machineId):\(method)",
            params: encodedParams,
            timeout: timeout
        )
        return try decodeRPCResult(raw, resourceId: machineId, prefersDataKey: prefersDataKey)
    }

    // MARK: - Sessions / Machines / Messages API

    func fetchSessions(machineId: String? = nil) async throws -> [CLISession] {
        var path = "/v1/sessions"
        if let machineId, !machineId.isEmpty,
           let encoded = machineId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "?machineId=\(encoded)"
        }

        let (data, _) = try await authorizedRequest(path: path)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessionsRaw = payload["sessions"] as? [[String: Any]] else {
            return []
        }

        var sessions: [CLISession] = []
        for raw in sessionsRaw {
            if let session = decodeSession(raw) {
                sessions.append(session)
            }
        }

        sessions.sort { $0.updatedAt > $1.updatedAt }
        return sessions
    }

    func fetchSession(sessionId: String) async throws -> CLISession? {
        let sessions = try await fetchSessions()
        return sessions.first(where: { $0.id == sessionId })
    }

    func fetchMachines() async throws -> [RemoteMachine] {
        let (data, _) = try await authorizedRequest(path: "/v1/machines")
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }

        var machines: [RemoteMachine] = []

        for raw in payload {
            guard let machineId = raw["id"] as? String else { continue }

            let prefersDataKey: Bool
            if let encryptedDataKey = raw["dataEncryptionKey"] as? String,
               let encryption,
               encryption.initializeResource(resourceId: machineId, encryptedDataKeyBase64: encryptedDataKey) {
                prefersDataKey = true
            } else {
                prefersDataKey = false
            }
            var resolvedPrefersDataKey = prefersDataKey
            var metadataObject = decodeEncryptedObject(
                encrypted: raw["metadata"],
                resourceId: machineId,
                prefersDataKey: prefersDataKey
            ) as? [String: Any]
            var daemonStateObject = decodeEncryptedObject(
                encrypted: raw["daemonState"],
                resourceId: machineId,
                prefersDataKey: prefersDataKey
            ) as? [String: Any]

            if metadataObject == nil && daemonStateObject == nil {
                let fallbackMode = !prefersDataKey
                let fallbackMetadata = decodeEncryptedObject(
                    encrypted: raw["metadata"],
                    resourceId: machineId,
                    prefersDataKey: fallbackMode
                ) as? [String: Any]
                let fallbackDaemonState = decodeEncryptedObject(
                    encrypted: raw["daemonState"],
                    resourceId: machineId,
                    prefersDataKey: fallbackMode
                ) as? [String: Any]

                if fallbackMetadata != nil || fallbackDaemonState != nil {
                    resolvedPrefersDataKey = fallbackMode
                    metadataObject = fallbackMetadata
                    daemonStateObject = fallbackDaemonState
                }
            }
            machineUsesDataKey[machineId] = resolvedPrefersDataKey

            let host = (metadataObject?["host"] as? String) ?? "Unknown"
            let displayName = (metadataObject?["displayName"] as? String) ?? host
            let homeDir = (metadataObject?["homeDir"] as? String) ?? NSHomeDirectory()
            let runtimeType = metadataObject?["runtimeType"] as? String
            let daemonPid = parseInt(daemonStateObject?["pid"])
            let daemonStatus = daemonStateObject?["status"] as? String

            let machine = RemoteMachine(
                id: machineId,
                displayName: displayName,
                host: host,
                homeDir: homeDir,
                runtimeType: runtimeType,
                daemonPid: daemonPid,
                daemonStatus: daemonStatus,
                active: raw["active"] as? Bool ?? false,
                activeAt: parseDate(raw["activeAt"]) ?? Date()
            )
            machines.append(machine)
        }

        machines.sort { $0.activeAt > $1.activeAt }
        return machines
    }

    func fetchMachine(machineId: String) async throws -> RemoteMachine? {
        let machines = try await fetchMachines()
        return machines.first(where: { $0.id == machineId })
    }

    func fetchDecodedMessages(sessionId: String, sinceSeq: Int? = nil) async throws -> DecodedMessageBatch {
        _ = try await resolveSessionPrefersDataKey(sessionId: sessionId)
        if supportsV2MessagesAPI != false {
            do {
                let batch = try await fetchDecodedMessagesV2(sessionId: sessionId, sinceSeq: sinceSeq)
                supportsV2MessagesAPI = true
                return batch
            } catch {
                if shouldDisableV2MessagesAPI(for: error) {
                    supportsV2MessagesAPI = false
                }
                print("⚠️ [RelayClient] v2 messages failed, fallback to v1: \(error.localizedDescription)")
            }
        }
        return try await fetchDecodedMessagesV1(sessionId: sessionId, sinceSeq: sinceSeq)
    }

    private func fetchDecodedMessagesV1(sessionId: String, sinceSeq: Int? = nil) async throws -> DecodedMessageBatch {
        let isIncremental = (sinceSeq ?? 0) > 0
        var queryItems: [URLQueryItem] = []
        queryItems.append(URLQueryItem(name: "limit", value: isIncremental ? "500" : "150"))
        if let sinceSeq, sinceSeq > 0 {
            queryItems.append(URLQueryItem(name: "sinceSeq", value: "\(sinceSeq)"))
        }

        let escapedSessionId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        var components = URLComponents()
        components.path = "/v1/sessions/\(escapedSessionId)/messages"
        components.queryItems = queryItems
        let path = components.string ?? "/v1/sessions/\(escapedSessionId)/messages"

        let (data, _) = try await authorizedRequest(path: path)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessages = payload["messages"] as? [[String: Any]] else {
            return DecodedMessageBatch(messages: [], nextSinceSeq: sinceSeq ?? 0, hasMore: false)
        }
        return decodeDecodedMessageBatch(
            sessionId: sessionId,
            sinceSeq: sinceSeq,
            rawMessages: rawMessages,
            payload: payload,
            messagesAreAscending: isIncremental
        )
    }

    private func fetchDecodedMessagesV2(sessionId: String, sinceSeq: Int? = nil) async throws -> DecodedMessageBatch {
        // Treat explicit sinceSeq (including 0) as forward pagination mode.
        let isIncremental = sinceSeq != nil
        var queryItems: [URLQueryItem] = []
        queryItems.append(URLQueryItem(name: "limit", value: isIncremental ? "500" : "150"))
        if let sinceSeq {
            queryItems.append(URLQueryItem(name: "sinceSeq", value: "\(sinceSeq)"))
        } else {
            queryItems.append(URLQueryItem(name: "direction", value: "backward"))
        }

        let escapedSessionId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        var components = URLComponents()
        components.path = "/v2/sessions/\(escapedSessionId)/messages"
        components.queryItems = queryItems
        let path = components.string ?? "/v2/sessions/\(escapedSessionId)/messages"

        let (data, _) = try await authorizedRequest(path: path)
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawMessages = payload["messages"] as? [[String: Any]] else {
            return DecodedMessageBatch(messages: [], nextSinceSeq: sinceSeq ?? 0, hasMore: false)
        }
        var batch = decodeDecodedMessageBatch(
            sessionId: sessionId,
            sinceSeq: sinceSeq,
            rawMessages: rawMessages,
            payload: payload,
            messagesAreAscending: true
        )
        if !isIncremental {
            batch = DecodedMessageBatch(
                messages: batch.messages,
                nextSinceSeq: batch.nextSinceSeq,
                hasMore: false
            )
        }
        return batch
    }

    private func decodeDecodedMessageBatch(
        sessionId: String,
        sinceSeq: Int?,
        rawMessages: [[String: Any]],
        payload: [String: Any],
        messagesAreAscending: Bool
    ) -> DecodedMessageBatch {
        let orderedMessages = messagesAreAscending ? rawMessages : Array(rawMessages.reversed())
        var decoded: [[String: Any]] = []
        var maxSeq = sinceSeq ?? 0

        for raw in orderedMessages {
            guard let mapped = decodeIncomingMessage(raw, sessionId: sessionId) else { continue }
            if let seq = raw["seq"] as? Int {
                maxSeq = max(maxSeq, seq)
            }
            decoded.append(mapped)
        }

        let nextSinceSeq = (payload["nextSinceSeq"] as? Int) ?? maxSeq
        sessionLastSeq[sessionId] = max(sessionLastSeq[sessionId] ?? 0, nextSinceSeq)

        return DecodedMessageBatch(
            messages: decoded,
            nextSinceSeq: nextSinceSeq,
            hasMore: payload["hasMore"] as? Bool ?? false
        )
    }

    private func shouldDisableV2MessagesAPI(for error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        if message.contains("route get:/v2/sessions") {
            return true
        }
        if message.contains("cannot get /v2/sessions") {
            return true
        }
        if message.contains("/v2/sessions") && message.contains("not found") {
            return true
        }
        return false
    }

    func syncSessionsToLocal(agentId: String, repository: LocalSessionRepository) async throws -> [CLISession] {
        let remoteSessions = try await fetchSessions()
        let localSessions = try await repository.getAllSessionsIncludingArchived(agentId: agentId)

        let remoteById = Dictionary(uniqueKeysWithValues: remoteSessions.map { ($0.id, $0) })
        var localByCliId: [String: ContextGoSession] = [:]
        var localById: [String: ContextGoSession] = [:]

        for local in localSessions {
            localById[local.id] = local
            if let cliId = local.cliSessionId {
                localByCliId[cliId] = local
            }
        }

        func mergeRemote(_ remote: CLISession, into local: ContextGoSession) -> ContextGoSession {
            var updated = local
            updated.title = remote.displayName
            if let summaryText = remote.metadata?.summary?.text, !summaryText.isEmpty {
                updated.preview = summaryText
            }
            updated.updatedAt = remote.updatedAt
            updated.lastMessageTime = remote.activeAt
            updated.isActive = remote.active
            // Preserve local archive state so archived sessions do not reappear as active-list entries
            // after a remote sync refresh.
            updated.isArchived = local.isArchived
            updated.syncStatus = .synced
            updated.lastSyncAt = Date()
            updated.tags = buildTags(flavor: remote.metadata?.flavor)

            var metadata = local.channelMetadataDict ?? [:]
            let freshMetadata = buildChannelMetadata(from: remote, agentId: agentId)
            for (key, value) in freshMetadata {
                metadata[key] = value
            }
            updated.setChannelMetadata(metadata)
            return updated
        }

        func isUniqueConstraintError(_ error: Error) -> Bool {
            let text = error.localizedDescription.lowercased()
            return text.contains("unique constraint failed") || text.contains("constraint failed")
        }

        for remote in remoteSessions {
            if let existing = localByCliId[remote.id] ?? localById[remote.id] {
                let updated = mergeRemote(remote, into: existing)
                try await repository.updateSession(updated, notifyCloud: false)
                localById[updated.id] = updated
                localByCliId[remote.id] = updated
            } else {
                var created = ContextGoSession(
                    id: remote.id,
                    agentId: agentId,
                    title: remote.displayName,
                    preview: remote.metadata?.summary?.text ?? "",
                    tags: buildTags(flavor: remote.metadata?.flavor),
                    createdAt: remote.createdAt,
                    updatedAt: remote.updatedAt,
                    lastMessageTime: remote.activeAt,
                    isActive: remote.active,
                    isPinned: false,
                    isArchived: false,
                    channelMetadata: nil,
                    messagesCachePath: SessionStorageLayout.messagesRelativePath(agentId: agentId, sessionId: remote.id),
                    syncStatus: .synced,
                    lastSyncAt: Date()
                )
                created.setChannelMetadata(buildChannelMetadata(from: remote, agentId: agentId))

                do {
                    try await repository.createSession(created, notifyCloud: false)
                    localById[created.id] = created
                    localByCliId[remote.id] = created
                } catch {
                    // Handle stale metadata / concurrent sync races:
                    // if row already exists, convert this create path into update.
                    guard isUniqueConstraintError(error),
                          let existingById = try await repository.getSession(id: remote.id),
                          existingById.agentId == agentId else {
                        throw error
                    }

                    let healed = mergeRemote(remote, into: existingById)
                    try await repository.updateSession(healed, notifyCloud: false)
                    localById[healed.id] = healed
                    localByCliId[remote.id] = healed
                }
            }
        }

        for local in localSessions {
            guard let cliId = local.cliSessionId else { continue }
            guard remoteById[cliId] == nil, !local.isArchived else { continue }

            var archived = local
            archived.markRemoteDeleted(provider: "cli")
            try await repository.updateSession(archived, notifyCloud: false)
        }

        NotificationCenter.default.post(
            name: NSNotification.Name("CLISessionsSynced"),
            object: nil,
            userInfo: ["botId": agentId, "count": remoteSessions.count]
        )

        return remoteSessions
    }

    func spawnSession(
        machineId: String,
        directory: String,
        flavor: String,
        approvedNewDirectoryCreation: Bool = false
    ) async throws -> SpawnSessionResult {
        let params: [String: Any] = [
            "type": "spawn-in-directory",
            "directory": directory,
            "approvedNewDirectoryCreation": approvedNewDirectoryCreation,
            "agent": flavor
        ]

        let raw = try await machineRPC(machineId: machineId, method: "spawn-cgo-session", params: params)
        guard let dict = raw as? [String: Any] else {
            return .error(message: "Invalid spawn response")
        }

        if let type = dict["type"] as? String {
            switch type {
            case "success":
                if let sessionId = dict["sessionId"] as? String {
                    return .success(sessionId: sessionId)
                }
                return .error(message: "Missing sessionId")
            case "requestToApproveDirectoryCreation":
                let directory = dict["directory"] as? String ?? directory
                return .requestDirectoryApproval(directory: directory)
            case "error":
                let errorMessage = dict["errorMessage"] as? String ?? "Failed to spawn session"
                return .error(message: errorMessage)
            default:
                break
            }
        }

        if let sessionId = dict["sessionId"] as? String {
            return .success(sessionId: sessionId)
        }

        if let errorMessage = dict["error"] as? String {
            return .error(message: errorMessage)
        }

        return .error(message: "Unexpected spawn response")
    }

    func sendUserMessage(
        sessionId: String,
        text: String,
        localId: String = UUID().uuidString,
        displayText: String? = nil,
        additionalMetadata: [String: Any]? = nil
    ) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        try await ensureConnected()

        let prefersDataKey = try await resolveSessionPrefersDataKey(sessionId: sessionId)

        var metadata: [String: Any] = [
            "sentFrom": "ios"
        ]
        if let displayText, !displayText.isEmpty {
            metadata["displayText"] = displayText
        }
        if let additionalMetadata {
            for (key, value) in additionalMetadata {
                metadata[key] = value
            }
        }

        let rawRecord: [String: Any] = [
            "role": "user",
            "content": [
                "type": "text",
                "text": trimmed
            ],
            "meta": metadata
        ]

        guard let encryptedRecord = try encodeRPCParams(
            rawRecord,
            resourceId: sessionId,
            prefersDataKey: prefersDataKey
        ) as? String else {
            throw RPCError.encodeFailed
        }

        try await emitSocketEvent(
            "message",
            payload: [
                "sid": sessionId,
                "message": encryptedRecord,
                "localId": localId,
                "sentFrom": "ios"
            ]
        )
    }

    func killSession(sessionId: String) async -> SessionActionResult {
        do {
            let raw = try await sessionRPC(method: "killSession", params: [:], to: sessionId, timeout: 20)
            if let dict = raw as? [String: Any] {
                let success = dict["success"] as? Bool ?? true
                let message = dict["message"] as? String ?? (success ? "Session archived" : "Failed to archive session")
                return SessionActionResult(success: success, message: message)
            }
            return SessionActionResult(success: true, message: "Session archived")
        } catch RPCError.invalidResponse {
            // Kill request likely delivered, but response body could not be decoded.
            return SessionActionResult(success: true, message: "Archive requested (ack decode failed)")
        } catch {
            do {
                let deleted = try await deleteSession(sessionId: sessionId)
                if deleted {
                    return SessionActionResult(success: true, message: "Session deleted (CLI unreachable)")
                }
            } catch {
                return SessionActionResult(success: false, message: error.localizedDescription)
            }
            return SessionActionResult(success: false, message: error.localizedDescription)
        }
    }

    func stopHostProcess(sessionId: String) async -> SessionActionResult {
        do {
            let raw = try await sessionRPC(method: "killSession", params: [:], to: sessionId, timeout: 20)
            if let dict = raw as? [String: Any] {
                let success = dict["success"] as? Bool ?? true
                let message = dict["message"] as? String ?? (success ? "Host process stop requested" : "Failed to stop host process")
                return SessionActionResult(success: success, message: message)
            }
            return SessionActionResult(success: true, message: "Host process stop requested")
        } catch RPCError.invalidResponse {
            return SessionActionResult(success: true, message: "Host process stop requested (ack decode failed)")
        } catch {
            return SessionActionResult(success: false, message: error.localizedDescription)
        }
    }

    func deleteSession(sessionId: String) async throws -> Bool {
        let escapedSessionId = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        let (data, response) = try await authorizedRequest(path: "/v1/sessions/\(escapedSessionId)", method: "DELETE")

        guard (200...299).contains(response.statusCode) else {
            return false
        }

        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let success = payload["success"] as? Bool {
            return success
        }
        return true
    }

    // MARK: - RPC encode/decode helpers

    private func encodeRPCParams(_ params: [String: Any], resourceId: String, prefersDataKey: Bool) throws -> Any {
        guard let encryption else {
            return params
        }
        return try encryption.encryptJSONObject(params, resourceId: resourceId, prefersDataKey: prefersDataKey)
    }

    private func decodeRPCResult(_ value: Any, resourceId: String, prefersDataKey: Bool) throws -> Any {
        guard let encrypted = value as? String else {
            return value
        }

        guard let encryption,
              let decrypted = encryption.decryptJSONObject(base64String: encrypted, resourceId: resourceId, prefersDataKey: prefersDataKey) else {
            throw RPCError.invalidResponse
        }

        return decrypted
    }

    private func sendRPCWithResponseRaw(
        fullMethod: String,
        params: Any,
        timeout: TimeInterval
    ) async throws -> Any {
        try await ensureConnected()

        let requestId = nextRPCRequestId
        nextRPCRequestId += 1

        let rpcCall: [String: Any] = [
            "method": fullMethod,
            "params": params
        ]

        let eventArray: [Any] = ["rpc-call", rpcCall]

        return try await withCheckedThrowingContinuation { continuation in
            let timeoutTask = Task { [weak self] in
                guard timeout > 0 else { return }
                let timeoutNanoseconds = UInt64(timeout * 1_000_000_000)
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)

                await MainActor.run {
                    guard let self,
                          let pending = self.pendingRPCResponses.removeValue(forKey: requestId) else {
                        return
                    }

                    pending.continuation.resume(throwing: RPCError.timeout(method: fullMethod))
                }
            }

            pendingRPCResponses[requestId] = PendingRPCResponse(
                continuation: continuation,
                timeoutTask: timeoutTask
            )

            guard let eventData = try? JSONSerialization.data(withJSONObject: eventArray),
                  let eventJSON = String(data: eventData, encoding: .utf8) else {
                if let pending = pendingRPCResponses.removeValue(forKey: requestId) {
                    pending.timeoutTask.cancel()
                    pending.continuation.resume(throwing: RPCError.encodeFailed)
                }
                return
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    try await self.sendAwaitingDelivery(text: "42\(requestId)" + eventJSON)
                } catch {
                    if let pending = self.pendingRPCResponses.removeValue(forKey: requestId) {
                        pending.timeoutTask.cancel()
                        pending.continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - ACP Replay Helpers

    func buildReplayMessagePayload(
        sessionId: String,
        eventType: String,
        eventPayload: [String: Any],
        sequence: Int,
        timestamp: Date = Date(),
        forceFallbackForEmptyEvent: Bool = false,
        uniquifyIdentifiers: Bool = false
    ) -> [String: Any]? {
        var payload = eventPayload
        if payload["type"] == nil {
            payload["type"] = eventType
        }
        if payload["session_id"] == nil, payload["sessionId"] == nil {
            payload["session_id"] = sessionId
        }
        if uniquifyIdentifiers {
            payload = uniquifyReplayPayloadIdentifiers(payload, sequence: sequence)
        }

        let canonicalType = canonicalACPEventType((payload["type"] as? String) ?? eventType)
        let safeSessionId = safeReplayIdentifierComponent(sessionId)
        let typeComponent = safeReplayIdentifierComponent(canonicalType.isEmpty ? eventType : canonicalType)
        let messageId = "replay.\(safeSessionId).\(sequence).\(typeComponent)"
        let timestampMs = timestamp.timeIntervalSince1970 * 1000

        let rawRecord: [String: Any] = [
            "role": "agent",
            "content": [
                "type": "acp",
                "data": payload
            ]
        ]

        if let normalized = normalizeRawRecord(
            rawRecord,
            rawMessageId: messageId,
            localId: nil,
            timestampMs: timestampMs,
            seq: sequence
        ) {
            return normalized
        }

        guard forceFallbackForEmptyEvent else {
            return nil
        }

        let fallbackType = canonicalType.isEmpty ? eventType : canonicalType
        return [
            "id": messageId,
            "rawMessageId": messageId,
            "role": "assistant",
            "content": [[
                "type": "event",
                "name": "acp-replay-fallback",
                "text": "[ACP Replay] \(fallbackType)"
            ]],
            "timestamp": timestampMs,
            "seq": sequence
        ]
    }

    @discardableResult
    func injectReplayACPEvent(
        sessionId: String,
        eventType: String,
        eventPayload: [String: Any],
        sequence: Int,
        timestamp: Date = Date(),
        forceFallbackForEmptyEvent: Bool = false,
        uniquifyIdentifiers: Bool = false
    ) -> Bool {
        guard let normalized = buildReplayMessagePayload(
            sessionId: sessionId,
            eventType: eventType,
            eventPayload: eventPayload,
            sequence: sequence,
            timestamp: timestamp,
            forceFallbackForEmptyEvent: forceFallbackForEmptyEvent,
            uniquifyIdentifiers: uniquifyIdentifiers
        ) else {
            return false
        }
        onNewMessage?(sessionId, normalized)
        newMessageSubject.send((sessionId: sessionId, messageData: normalized))
        return true
    }

    private func uniquifyReplayPayloadIdentifiers(_ payload: [String: Any], sequence: Int) -> [String: Any] {
        var output = payload
        let suffix = "#r\(sequence)"
        let idKeys: Set<String> = [
            "id",
            "call_id",
            "callId",
            "item_id",
            "itemId",
            "turn_id",
            "turnId",
            "thread_id",
            "threadId",
            "tool_use_id",
            "toolUseId",
            "toolCallId",
            "tool_call_id",
            "permissionId",
            "permission_id",
            "approval_id",
            "approvalId",
            "taskId",
            "task_id",
            "receiver_thread_id",
            "sender_thread_id"
        ]

        for key in idKeys {
            guard let value = output[key] else { continue }
            if let id = value as? String {
                output[key] = id.hasSuffix(suffix) ? id : "\(id)\(suffix)"
            } else if let ids = value as? [String] {
                output[key] = ids.map { id in
                    id.hasSuffix(suffix) ? id : "\(id)\(suffix)"
                }
            }
        }

        return output
    }

    private func safeReplayIdentifierComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "value" }

        let sanitized = trimmed.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        return sanitized.isEmpty ? "value" : sanitized
    }

    // MARK: - Message decode

    private func decodeIncomingMessage(_ rawMessage: [String: Any], sessionId: String) -> [String: Any]? {
        let rawMessageId = rawMessage["id"] as? String ?? UUID().uuidString
        let localId = rawMessage["localId"] as? String
        let createdAtMs = parseMilliseconds(rawMessage["createdAt"]) ?? Date().timeIntervalSince1970 * 1000
        let seq = rawMessage["seq"] as? Int

        let rawRecord: [String: Any]?
        if let contentDict = rawMessage["content"] as? [String: Any],
           (contentDict["t"] as? String) == "encrypted",
           let encrypted = contentDict["c"] as? String {
            let preferredMode = sessionUsesDataKey[sessionId] ?? true
            let primaryDecoded = decodeEncryptedObject(
                encrypted: encrypted,
                resourceId: sessionId,
                prefersDataKey: preferredMode
            ) as? [String: Any]

            if primaryDecoded == nil {
                let fallbackMode = !preferredMode
                let fallbackDecoded = decodeEncryptedObject(
                    encrypted: encrypted,
                    resourceId: sessionId,
                    prefersDataKey: fallbackMode
                ) as? [String: Any]
                if fallbackDecoded != nil {
                    sessionUsesDataKey[sessionId] = fallbackMode
                }
                rawRecord = fallbackDecoded
            } else {
                rawRecord = primaryDecoded
            }
        } else {
            rawRecord = rawMessage
        }

        guard let rawRecord else { return nil }
        if let activity = activityStateFromRuntimeEvent(rawRecord) {
            publishSessionActivity(sessionId: sessionId, state: activity)
        }
        return normalizeRawRecord(
            rawRecord,
            rawMessageId: rawMessageId,
            localId: localId,
            timestampMs: createdAtMs,
            seq: seq
        )
    }

    private func normalizeRawRecord(
        _ rawRecord: [String: Any],
        rawMessageId: String,
        localId: String?,
        timestampMs: Double,
        seq: Int?
    ) -> [String: Any]? {
        guard let role = rawRecord["role"] as? String else {
            return nil
        }

        if role == "user" {
            if let content = rawRecord["content"] as? [String: Any],
               let text = content["text"] as? String,
               !text.isEmpty {
                let displayId = (localId?.isEmpty == false) ? (localId ?? rawMessageId) : rawMessageId
                var result: [String: Any] = [
                    "id": displayId,
                    "rawMessageId": rawMessageId,
                    "role": "user",
                    "content": [["type": "text", "text": text]],
                    "timestamp": timestampMs
                ]
                if let localId, !localId.isEmpty {
                    result["localId"] = localId
                }
                if let seq { result["seq"] = seq }
                return result
            }
            return nil
        }

        guard role == "agent" else {
            return nil
        }

        let extracted = extractAgentBlocks(from: rawRecord)
        guard !extracted.blocks.isEmpty else {
            return nil
        }

        var sanitizedBlocks: [[String: Any]] = []
        sanitizedBlocks.reserveCapacity(extracted.blocks.count)
        var roleOverride: String?
        for block in extracted.blocks {
            var mutable = block
            if roleOverride == nil,
               let marker = (mutable["_role"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
               marker == "user" || marker == "assistant" {
                roleOverride = marker
            }
            mutable.removeValue(forKey: "_role")
            sanitizedBlocks.append(mutable)
        }

        var result: [String: Any] = [
            "id": rawMessageId,
            "rawMessageId": rawMessageId,
            "role": roleOverride ?? extracted.role,
            "content": sanitizedBlocks,
            "timestamp": timestampMs
        ]
        if let runId = extracted.runId, !runId.isEmpty {
            result["runId"] = runId
        }
        if let parentRunId = extracted.parentRunId, !parentRunId.isEmpty {
            result["parentRunId"] = parentRunId
        }
        if extracted.isSidechain {
            result["isSidechain"] = true
        }
        if let seq { result["seq"] = seq }
        return result
    }

    private func activityStateFromRuntimeEvent(_ rawRecord: [String: Any]) -> ActivityState? {
        guard let role = (rawRecord["role"] as? String)?.lowercased(), role == "agent" else {
            return nil
        }
        guard let content = rawRecord["content"] as? [String: Any] else {
            return nil
        }

        let contentType = canonicalACPEventType((content["type"] as? String) ?? "")
        switch contentType {
        case "event":
            if let data = content["data"] as? [String: Any] {
                if let state = activityStateFromRuntimeMarker(data["type"] as? String) {
                    return state
                }
                if let state = activityStateFromRuntimeMarker(data["status"] as? String) {
                    return state
                }
                if let state = activityStateFromRuntimeMarker(data["state"] as? String) {
                    return state
                }
            }
            return nil

        case "acp", "codex":
            guard let data = content["data"] as? [String: Any] else {
                return nil
            }
            if let state = activityStateFromRuntimeMarker(data["type"] as? String) {
                return state
            }
            if canonicalACPEventType((data["type"] as? String) ?? "") == "event" {
                if let state = activityStateFromRuntimeMarker(data["name"] as? String) {
                    return state
                }
                if let payload = data["payload"] as? [String: Any] {
                    if let state = activityStateFromRuntimeMarker(payload["type"] as? String) {
                        return state
                    }
                    if let state = activityStateFromRuntimeMarker(payload["status"] as? String) {
                        return state
                    }
                    if let state = activityStateFromRuntimeMarker(payload["state"] as? String) {
                        return state
                    }
                }
            }
            return nil

        default:
            return nil
        }
    }

    private func activityStateFromRuntimeMarker(_ raw: String?) -> ActivityState? {
        let marker = canonicalACPEventType((raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
        guard !marker.isEmpty else { return nil }

        switch marker {
        case "ready", "idle":
            return .idle
        case "thinking":
            return .thinking
        case "waiting.for.permission", "waiting_for_permission", "permission.request", "request.permission":
            return .waitingForPermission
        default:
            return nil
        }
    }

    private func extractAgentBlocks(from rawRecord: [String: Any]) -> (
        role: String,
        blocks: [[String: Any]],
        runId: String?,
        parentRunId: String?,
        isSidechain: Bool
    ) {
        guard let content = rawRecord["content"] as? [String: Any],
              let type = (content["type"] as? String)?.lowercased() else {
            return ("assistant", [], nil, nil, false)
        }

        switch type {
        case "output":
            return parseOutputContent(content["data"])
        case "acp", "codex":
            let providerHint = (content["provider"] as? String) ?? (content["flavor"] as? String)
            let parsed = parseACPContent(
                content["data"] as? [String: Any],
                providerHint: providerHint,
                contentType: type
            )
            return ("assistant", parsed.blocks, parsed.runId, nil, false)
        case "event":
            if let data = content["data"] as? [String: Any],
               let message = data["message"] as? String,
               !message.isEmpty {
                if shouldSuppressProtocolEventText(message) {
                    return ("assistant", [], nil, nil, false)
                }
                return ("assistant", [["type": "event", "text": message]], nil, nil, false)
            }
            return ("assistant", [], nil, nil, false)
        default:
            return ("assistant", [], nil, nil, false)
        }
    }

    private func parseOutputContent(_ value: Any?) -> (
        role: String,
        blocks: [[String: Any]],
        runId: String?,
        parentRunId: String?,
        isSidechain: Bool
    ) {
        guard let data = value as? [String: Any],
              let dataType = (data["type"] as? String)?.lowercased() else {
            return ("assistant", [], nil, nil, false)
        }

        let uuid = data["uuid"] as? String
        let parentUUID = data["parentUuid"] as? String
        let isSidechain = data["isSidechain"] as? Bool ?? false

        switch dataType {
        case "assistant":
            var blocks: [[String: Any]] = []
            if let message = data["message"] as? [String: Any] {
                if let text = message["content"] as? String, !text.isEmpty {
                    var block: [String: Any] = ["type": "text", "text": text]
                    attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
                    blocks.append(block)
                } else if let items = message["content"] as? [[String: Any]] {
                    for item in items {
                        blocks.append(contentsOf: parseMessageContentItem(item, uuid: uuid, parentUUID: parentUUID))
                    }
                }
            }
            return ("assistant", blocks, uuid, parentUUID, isSidechain)

        case "user":
            if let message = data["message"] as? [String: Any] {
                if let text = message["content"] as? String, !text.isEmpty {
                    var block: [String: Any] = ["type": "text", "text": text]
                    attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
                    return ("user", [block], uuid, parentUUID, isSidechain)
                }
                if let items = message["content"] as? [[String: Any]] {
                    var blocks: [[String: Any]] = []
                    for item in items {
                        blocks.append(contentsOf: parseMessageContentItem(item, uuid: uuid, parentUUID: parentUUID))
                    }
                    if !blocks.isEmpty {
                        let containsToolBlock = blocks.contains { block in
                            let type = (block["type"] as? String)?.lowercased()
                            return type == "tool_use" || type == "tool_result"
                        }
                        return (containsToolBlock ? "assistant" : "user", blocks, uuid, parentUUID, isSidechain)
                    }

                    var texts: [String] = []
                    for item in items {
                        if let text = item["text"] as? String, !text.isEmpty {
                            texts.append(text)
                        }
                    }
                    if !texts.isEmpty {
                        var block: [String: Any] = ["type": "text", "text": texts.joined(separator: "\n")]
                        attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
                        return ("user", [block], uuid, parentUUID, isSidechain)
                    }
                }
            }
            return ("user", [], uuid, parentUUID, isSidechain)

        case "summary":
            if let summary = data["summary"] as? String, !summary.isEmpty {
                var block: [String: Any] = ["type": "text", "text": summary]
                attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
                return ("assistant", [block], uuid, parentUUID, isSidechain)
            }
            return ("assistant", [], uuid, parentUUID, isSidechain)

        case "message", "reasoning":
            if let message = (data["message"] as? String) ?? (data["text"] as? String), !message.isEmpty {
                var block: [String: Any] = ["type": "text", "text": message]
                attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
                return ("assistant", [block], uuid, parentUUID, isSidechain)
            }
            return ("assistant", [], uuid, parentUUID, isSidechain)

        default:
            return ("assistant", [], uuid, parentUUID, isSidechain)
        }
    }

    private func extractACPChunkText(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }

        if let dict = value as? [String: Any] {
            if let text = dict["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let content = dict["content"] as? [String: Any],
               let text = content["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let nested = dict["content"] as? String,
               !nested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nested
            }
        }

        if let array = value as? [[String: Any]] {
            for item in array {
                if let text = extractACPChunkText(item) {
                    return text
                }
            }
        }

        return nil
    }

    private func parseACPContent(
        _ data: [String: Any]?,
        providerHint: String?,
        contentType: String
    ) -> (blocks: [[String: Any]], runId: String?) {
        guard let rawData = data else {
            return ([], nil)
        }

        let normalized = normalizeACPEventPayload(rawData)
        let baseType = (normalized["type"] as? String) ?? (normalized["method"] as? String) ?? "event"
        let canonicalType = canonicalACPEventType(baseType)
        let claudeEnabled = isClaudeACPProvider(
            providerHint: providerHint,
            contentType: contentType
        )
        let codexEnabled = isCodexACPProvider(
            providerHint: providerHint,
            contentType: contentType
        )
        let opencodeEnabled = isOpenCodeACPProvider(
            providerHint: providerHint,
            contentType: contentType
        )
        let messageId = preferredACPMessageIdentifier(from: normalized)
        let runId = preferredACPEventRunIdentifier(from: normalized, fallback: messageId)

        if opencodeEnabled,
           let parsed = parseOpenCodeACPContent(
            normalized: normalized,
            canonicalType: canonicalType,
            messageId: messageId,
            fallbackRunId: runId
           ) {
            return parsed
        }

        if codexEnabled,
           let parsed = parseCodexACPContent(
            normalized: normalized,
            canonicalType: canonicalType,
            messageId: messageId,
            fallbackRunId: runId
           ) {
            return parsed
        }

        if claudeEnabled,
           let parsed = parseClaudeACPContent(
            normalized: normalized,
            canonicalType: canonicalType,
            messageId: messageId,
            fallbackRunId: runId
           ) {
            return parsed
        }

        let resolved = resolveACPEnvelope(normalized: normalized, canonicalType: canonicalType)
        return parseGenericACPContent(
            resolvedType: resolved.type,
            resolvedPayload: resolved.payload,
            normalized: normalized,
            messageId: messageId,
            fallbackRunId: runId
        )
    }

    private func isCodexACPProvider(
        providerHint: String?,
        contentType: String
    ) -> Bool {
        if contentType == "codex" {
            return true
        }

        if let provider = providerHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           provider == "codex" {
            return true
        }
        return false
    }

    private func parseCodexACPContent(
        normalized: [String: Any],
        canonicalType: String,
        messageId: String?,
        fallbackRunId: String?
    ) -> (blocks: [[String: Any]], runId: String?)? {
        if isCodexSilentEnvelopeType(canonicalType) {
            return ([], fallbackRunId)
        }

        let resolved = resolveACPEnvelope(normalized: normalized, canonicalType: canonicalType)
        if isCodexSilentEnvelopeType(resolved.type) {
            return ([], fallbackRunId)
        }

        let codexPayload = (resolved.payload as? [String: Any]) ?? normalized

        if let wrappedName = (normalized["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !wrappedName.isEmpty,
           let wrappedPayload = normalized["payload"] as? [String: Any],
           let parsed = parseCodexEventFromEventWrapper(
            eventName: wrappedName,
            payload: wrappedPayload,
            messageId: messageId,
            fallbackRunId: fallbackRunId
           ) {
            return (parsed.blocks, parsed.runId ?? fallbackRunId)
        }

        if let parsed = parseCodexEventEnvelope(
            type: resolved.type,
            data: codexPayload,
            messageId: messageId
        ) {
            return (parsed.blocks, parsed.runId ?? fallbackRunId)
        }

        if let parsed = parseCodexACPEvent(
            type: resolved.type,
            data: codexPayload,
            messageId: messageId
        ) {
            return (parsed.blocks, parsed.runId ?? fallbackRunId)
        }

        if resolved.type == "message" || resolved.type == "agent.message.chunk" {
            if let text = extractACPChunkText(resolved.payload)
                ?? extractACPChunkText(normalized["content"] ?? normalized["message"] ?? normalized["text"]) {
                return ([["type": "text", "text": text]], fallbackRunId)
            }
        }

        if resolved.type == "user.message.chunk" {
            if let text = extractACPChunkText(resolved.payload)
                ?? extractACPChunkText(normalized["content"] ?? normalized["message"] ?? normalized["text"]) {
                return ([["type": "text", "text": text, "_role": "user"]], fallbackRunId)
            }
        }

        if resolved.type == "thinking"
            || resolved.type == "agent.thought.chunk"
            || resolved.type == "reasoning" {
            if let text = extractACPChunkText(resolved.payload)
                ?? extractACPChunkText(normalized["content"] ?? normalized["message"] ?? normalized["text"]) {
                return ([["type": "thinking", "text": text]], fallbackRunId)
            }
        }

        return nil
    }

    private func resolveACPEnvelope(
        normalized: [String: Any],
        canonicalType: String
    ) -> (type: String, payload: Any) {
        var resolvedType = canonicalType.isEmpty ? "event" : canonicalType
        var resolvedPayload: Any = normalized

        if resolvedType == "event" {
            let wrappedName = canonicalACPEventType((normalized["name"] as? String) ?? "")
            if !wrappedName.isEmpty {
                resolvedType = wrappedName
            }
            if let payload = normalized["payload"] {
                resolvedPayload = payload
            }
        }

        return (resolvedType, resolvedPayload)
    }

    private func parseGenericACPContent(
        resolvedType: String,
        resolvedPayload: Any,
        normalized: [String: Any],
        messageId: String?,
        fallbackRunId: String?
    ) -> (blocks: [[String: Any]], runId: String?) {
        let payloadDict = (resolvedPayload as? [String: Any]) ?? normalized
        let defaultToolId = firstNonEmptyString([
            payloadDict["toolUseId"] as? String,
            payloadDict["tool_use_id"] as? String,
            payloadDict["toolCallId"] as? String,
            payloadDict["tool_call_id"] as? String,
            payloadDict["callId"] as? String,
            payloadDict["call_id"] as? String,
            payloadDict["permissionId"] as? String,
            payloadDict["permission_id"] as? String,
            payloadDict["id"] as? String,
            messageId
        ]) ?? UUID().uuidString

        // Even without provider-specific routing, keep generic text envelopes readable.
        let textEnvelopeTypes: Set<String> = [
            "message",
            "agent.message",
            "agent.message.chunk"
        ]
        if textEnvelopeTypes.contains(resolvedType),
           let text = extractACPChunkText(resolvedPayload)
            ?? extractACPChunkText(
                payloadDict["content"]
                    ?? payloadDict["message"]
                    ?? payloadDict["text"]
                    ?? normalized["content"]
                    ?? normalized["message"]
                    ?? normalized["text"]
            ) {
            return ([["type": "text", "text": text]], fallbackRunId ?? defaultToolId)
        }

        let thinkingEnvelopeTypes: Set<String> = [
            "thinking",
            "reasoning",
            "agent.thought",
            "agent.thought.chunk"
        ]
        if thinkingEnvelopeTypes.contains(resolvedType),
           let text = extractACPChunkText(resolvedPayload)
            ?? extractACPChunkText(
                payloadDict["content"]
                    ?? payloadDict["message"]
                    ?? payloadDict["text"]
                    ?? normalized["content"]
                    ?? normalized["message"]
                    ?? normalized["text"]
            ) {
            return ([["type": "thinking", "text": text]], fallbackRunId ?? defaultToolId)
        }

        let permissionTypes: Set<String> = [
            "permission.request",
            "permission_request",
            "request.permission",
            "request_permission"
        ]

        if permissionTypes.contains(resolvedType) {
            var block: [String: Any] = [
                "type": "tool_use",
                "toolUseId": defaultToolId,
                "toolName": "protocol.\(resolvedType)",
                "toolInput": stringifyValue(resolvedPayload) ?? "{}",
                "description": resolvedType
            ]
            if let permission = parsePermissionPayload(
                payloadDict["permission"] ?? payloadDict["permissions"] ?? payloadDict
            ) {
                block["permission"] = permission
            } else {
                block["permission"] = [
                    "id": defaultToolId,
                    "status": "pending"
                ]
            }
            return ([block], fallbackRunId ?? defaultToolId)
        }

        let resultTypes: Set<String> = [
            "tool.result",
            "tool_result",
            "toolcall.result",
            "tool.result.error",
            "tool_result_error"
        ]

        if resultTypes.contains(resolvedType) {
            let outputText = stringifyValue(
                payloadDict["text"]
                    ?? payloadDict["output"]
                    ?? payloadDict["result"]
                    ?? payloadDict["content"]
                    ?? resolvedPayload
            ) ?? ""

            let isError = resolvedType.contains("error")
                || ((payloadDict["isError"] as? Bool) ?? false)
                || ((payloadDict["is_error"] as? Bool) ?? false)

            let block: [String: Any] = [
                "type": "tool_result",
                "toolUseId": defaultToolId,
                "toolName": "protocol.\(resolvedType)",
                "text": outputText,
                "isError": isError
            ]
            return ([block], fallbackRunId ?? defaultToolId)
        }

        var rawToolBlock: [String: Any] = [
            "type": "tool_use",
            "toolUseId": defaultToolId,
            "toolName": "protocol.\(resolvedType)",
            "toolInput": stringifyValue(resolvedPayload) ?? "{}",
            "description": resolvedType
        ]

        if let permission = parsePermissionPayload(payloadDict["permission"] ?? payloadDict["permissions"]) {
            rawToolBlock["permission"] = permission
        }

        return ([rawToolBlock], fallbackRunId ?? defaultToolId)
    }

    private func normalizeACPEventPayload(_ data: [String: Any]) -> [String: Any] {
        if let params = data["params"] as? [String: Any] {
            if let msg = params["msg"] as? [String: Any] {
                return msg
            }
            if let method = data["method"] as? String {
                var merged = params
                if merged["type"] == nil {
                    merged["type"] = method
                }
                if merged["id"] == nil, let id = data["id"] {
                    merged["id"] = id
                }
                return merged
            }
        }
        return data
    }

    func canonicalACPEventType(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return trimmed }
        let dotted = trimmed
            .replacingOccurrences(of: "/", with: ".")
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: "-", with: ".")
        let collapsed = dotted.replacingOccurrences(
            of: #"\.+"#,
            with: ".",
            options: .regularExpression
        )
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }

    private func parseMessageContentItem(
        _ item: [String: Any],
        uuid: String?,
        parentUUID: String?
    ) -> [[String: Any]] {
        guard let type = (item["type"] as? String)?.lowercased() else {
            return []
        }

        switch type {
        case "text", "output_text", "input_text":
            if let text = item["text"] as? String, !text.isEmpty {
                let blockType = isLikelyOpenCodePlanningScratchText(text) ? "thinking" : "text"
                var block: [String: Any] = ["type": blockType, "text": text]
                attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
                return [block]
            }

        case "thinking":
            if let text = (item["thinking"] as? String) ?? (item["text"] as? String), !text.isEmpty {
                var block: [String: Any] = ["type": "thinking", "text": text]
                attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
                return [block]
            }

        case "reasoning":
            if let text = item["text"] as? String, !text.isEmpty {
                var block: [String: Any] = ["type": "thinking", "text": text]
                attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
                return [block]
            }

        case "subtask":
            let id = (item["id"] as? String) ?? UUID().uuidString
            let input: [String: Any] = [
                "subagent_type": item["agent"] as Any,
                "description": item["description"] as Any,
                "prompt": item["prompt"] as Any,
                "model": item["model"] as Any,
                "command": item["command"] as Any
            ]
            var block: [String: Any] = [
                "type": "tool_use",
                "toolUseId": id,
                "toolName": "Task",
                "toolInput": stringifyValue(input) ?? "{}"
            ]
            if let description = item["description"] as? String, !description.isEmpty {
                block["description"] = description
            }
            attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
            return [block]

        case "tool":
            let id = (item["callID"] as? String)
                ?? (item["callId"] as? String)
                ?? (item["toolUseId"] as? String)
                ?? (item["toolCallId"] as? String)
                ?? (item["id"] as? String)
                ?? UUID().uuidString
            let baseName = normalizeToolName((item["tool"] as? String) ?? (item["name"] as? String) ?? "tool")
            let state = item["state"] as? [String: Any]
            let stateStatus = (state?["status"] as? String)?.lowercased() ?? ""
            let normalizedInput = normalizeToolInput(
                toolName: baseName,
                input: state?["input"] ?? item["input"] ?? item["arguments"]
            )
            var detectorPayload = item
            detectorPayload["input"] = normalizedInput as Any
            let name = resolveToolUseName(from: detectorPayload, fallbackName: baseName, normalizedInput: normalizedInput)

            var useBlock: [String: Any] = [
                "type": "tool_use",
                "toolUseId": id,
                "toolName": name,
                "toolInput": stringifyValue(normalizedInput) ?? "{}"
            ]
            if let toolKind = extractToolKindCandidate(from: item) {
                useBlock["toolKind"] = toolKind
            }
            if let description = (state?["title"] as? String) ?? (item["description"] as? String),
               !description.isEmpty {
                useBlock["description"] = description
            }
            if let permission = parsePermissionPayload(item["permissions"] ?? item["permission"]) {
                useBlock["permission"] = permission
            }
            attachRunContext(&useBlock, uuid: uuid, parentUUID: parentUUID)

            guard stateStatus == "completed" || stateStatus == "error" else {
                return [useBlock]
            }

            let resultPayload = state?["output"] ?? state?["error"] ?? state?["metadata"] ?? item["output"] ?? item["error"]
            var resultBlock: [String: Any] = [
                "type": "tool_result",
                "toolUseId": id,
                "toolName": name,
                "text": stringifyValue(resultPayload) ?? "",
                "isError": stateStatus == "error"
            ]
            if let toolKind = extractToolKindCandidate(from: item) {
                resultBlock["toolKind"] = toolKind
            }
            attachRunContext(&resultBlock, uuid: uuid, parentUUID: parentUUID)
            return [useBlock, resultBlock]

        case "step-start":
            let text = "Step started"
            var block: [String: Any] = ["type": "event", "text": text]
            attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
            return [block]

        case "step-finish":
            let reason = (item["reason"] as? String) ?? "completed"
            let cost = item["cost"] as? Double
            let text: String = {
                if let cost {
                    return "Step finished (\(reason), cost: \(cost))"
                }
                return "Step finished (\(reason))"
            }()
            var block: [String: Any] = ["type": "event", "text": text]
            attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
            return [block]

        case "retry":
            let errorText = stringifyValue(item["error"]) ?? "Retry requested"
            let id = (item["id"] as? String) ?? UUID().uuidString
            var block: [String: Any] = [
                "type": "tool_result",
                "toolUseId": id,
                "toolName": "retry",
                "text": errorText,
                "isError": true
            ]
            attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
            return [block]

        case "agent":
            if let name = item["name"] as? String, !name.isEmpty {
                var block: [String: Any] = ["type": "event", "text": "Agent: \(name)"]
                attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
                return [block]
            }

        case "snapshot":
            if let snapshot = item["snapshot"] as? String, !snapshot.isEmpty {
                var block: [String: Any] = ["type": "event", "text": "Snapshot: \(snapshot)"]
                attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
                return [block]
            }

        case "patch":
            let id = (item["id"] as? String) ?? UUID().uuidString
            let payload: [String: Any] = [
                "hash": item["hash"] as Any,
                "files": item["files"] as Any
            ]
            var block: [String: Any] = [
                "type": "tool_result",
                "toolUseId": id,
                "toolName": "patch",
                "text": stringifyValue(payload) ?? "",
                "isError": false
            ]
            attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
            return [block]

        case "file":
            let path = (item["filename"] as? String)
                ?? (item["url"] as? String)
                ?? "file"
            var block: [String: Any] = ["type": "event", "text": "File: \(path)"]
            attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
            return [block]

        case "compaction":
            var block: [String: Any] = ["type": "event", "text": "Context compaction"]
            attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
            return [block]

        case "tool_use", "tool-call", "tool_call", "toolcall":
            let id = (item["toolUseId"] as? String)
                ?? (item["toolCallId"] as? String)
                ?? (item["id"] as? String)
                ?? (item["callId"] as? String)
                ?? UUID().uuidString
            let baseName = normalizeToolName((item["toolName"] as? String) ?? (item["name"] as? String) ?? "tool")
            let normalizedInput = normalizeToolInput(
                toolName: baseName,
                input: preferredToolInputPayload(from: item)
            )
            let name = resolveToolUseName(from: item, fallbackName: baseName, normalizedInput: normalizedInput)
            var block: [String: Any] = [
                "type": "tool_use",
                "toolUseId": id,
                "toolName": name,
                "toolInput": stringifyValue(normalizedInput) ?? "{}"
            ]
            if let toolKind = extractToolKindCandidate(from: item) {
                block["toolKind"] = toolKind
            }
            if let description = sanitizeToolDescription(from: normalizedInput) {
                block["description"] = description
            }
            if let permission = parsePermissionPayload(item["permissions"] ?? item["permission"]) {
                block["permission"] = permission
            }
            attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
            return [block]

        case "tool_result", "tool-result", "toolresult", "tool-call-result", "tool_call_result", "tool_result_error":
            let id = (item["toolUseId"] as? String)
                ?? (item["toolCallId"] as? String)
                ?? (item["tool_use_id"] as? String)
                ?? (item["callId"] as? String)
                ?? (item["id"] as? String)
                ?? UUID().uuidString
            let text = extractToolResultText(item)
            let hasErrorPayload = item["error"] != nil
                || ((item["toolResult"] as? [String: Any])?["error"] != nil)
            let isError = ((item["is_error"] as? Bool) ?? (item["isError"] as? Bool) ?? false) || hasErrorPayload || type == "tool_result_error"
            var block: [String: Any] = [
                "type": "tool_result",
                "toolUseId": id,
                "text": text,
                "isError": isError
            ]
            if let toolName = extractToolNameCandidate(from: item) {
                block["toolName"] = toolName
            }
            if let toolKind = extractToolKindCandidate(from: item) {
                block["toolKind"] = toolKind
            }
            if let permission = parsePermissionPayload(item["permissions"] ?? item["permission"]) {
                block["permission"] = permission
            }
            attachRunContext(&block, uuid: uuid, parentUUID: parentUUID)
            return [block]

        default:
            if var fallback = makeUnsupportedProtocolToolResultBlock(
                sourceType: type,
                payload: item,
                fallbackId: (item["id"] as? String) ?? (item["uuid"] as? String)
            ) {
                attachRunContext(&fallback, uuid: uuid, parentUUID: parentUUID)
                return [fallback]
            }
        }

        return []
    }

    private func isLikelyOpenCodePlanningScratchText(_ text: String) -> Bool {
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

    private func makeUnsupportedProtocolToolResultBlock(
        sourceType: String,
        payload: [String: Any],
        fallbackId: String?
    ) -> [String: Any]? {
        let canonicalSourceType = canonicalACPEventType(sourceType)
        let normalizedCodexType = normalizeCodexACPType(canonicalSourceType)
        let codexLifecycleNoise: Set<String> = [
            "status",
            "item.started",
            "item.completed",
            "thread.started",
            "thread.archived",
            "thread.unarchived",
            "turn.started",
            "turn.completed",
            "task.started",
            "task.complete",
            "task.finished",
            "runtime.metadata",
            "event.runtime.metadata",
            "mcp.startup.complete",
            "mcp.startup.update"
        ]
        let explicitSilentEventTypes: Set<String> = [
            "event.thread.started",
            "event.thread.archived",
            "event.thread.unarchived",
            "event.account.updated",
            "event.account.ratelimits.updated",
            "event.item.reasoning.summarypartadded"
        ]

        guard sourceType != "token_count",
              sourceType != "runtime.metadata",
              sourceType != "event.runtime.metadata",
              canonicalSourceType != "token.count",
              canonicalSourceType != "runtime.metadata",
              canonicalSourceType != "event.runtime.metadata" else { return nil }

        if canonicalSourceType.hasPrefix("codex.")
            || canonicalSourceType.hasPrefix("event.codex.")
            || explicitSilentEventTypes.contains(canonicalSourceType)
            || codexLifecycleNoise.contains(normalizedCodexType) {
            // Codex lifecycle/status events should not render as protocol fallback cards.
            return nil
        }

        var normalizedPayload = payload
        normalizedPayload.removeValue(forKey: "type")
        normalizedPayload.removeValue(forKey: "id")

        if isStatusOnlyCompletionMarker(normalizedPayload) ||
            isStatusOnlyMarkerPayload(normalizedPayload["result"]) ||
            isStatusOnlyMarkerPayload(normalizedPayload["content"]) ||
            isStatusOnlyMarkerPayload(normalizedPayload["toolResult"]) {
            return nil
        }

        let raw = prettyJSONStringIfPossible(normalizedPayload)
            ?? stringifyValue(normalizedPayload)
            ?? prettyJSONStringIfPossible(payload)
            ?? stringifyValue(payload)
            ?? ""
        let rendered = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncatedPayload: String = {
            guard rendered.count > 3000 else { return rendered }
            return String(rendered.prefix(3000)) + "\n…(truncated)"
        }()

        let summary = "[未适配协议事件] \(sourceType)"
        let text = truncatedPayload.isEmpty ? summary : "\(summary)\n\(truncatedPayload)"
        let toolId = fallbackId ?? (payload["id"] as? String) ?? UUID().uuidString

        return [
            "type": "tool_result",
            "toolUseId": toolId,
            "toolName": "protocol.\(sourceType)",
            "text": text,
            "isError": false
        ]
    }

    private func isStatusOnlyMarkerPayload(_ value: Any?) -> Bool {
        guard let value else { return false }
        if let dict = value as? [String: Any] {
            return isStatusOnlyCompletionMarker(dict)
        }
        if let raw = value as? String,
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let dict = json as? [String: Any] {
            return isStatusOnlyCompletionMarker(dict)
        }
        return false
    }

    private func prettyJSONStringIfPossible(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return text
    }

    private func extractToolResultText(_ item: [String: Any]) -> String {
        if let rawOutput = item["rawOutput"] {
            return normalizedToolResultText(rawOutput)
        }

        if let toolResult = item["toolResult"] {
            return normalizedToolResultText(toolResult)
        }

        if let result = item["result"] {
            return normalizedToolResultText(result)
        }

        if let output = item["output"] {
            return normalizedToolResultText(output)
        }

        if let content = item["content"] as? String {
            return content
        }

        if let contentItems = item["content"] as? [[String: Any]] {
            let wrappedText = contentItems.compactMap { part -> String? in
                if let text = part["text"] as? String, !text.isEmpty {
                    return text
                }
                if let content = part["content"] as? [String: Any],
                   (content["type"] as? String) == "text",
                   let text = content["text"] as? String,
                   !text.isEmpty {
                    return text
                }
                return nil
            }

            if !wrappedText.isEmpty {
                return wrappedText.joined(separator: "\n")
            }
        }

        if let contentAny = item["content"] {
            return normalizedToolResultText(contentAny)
        }

        return ""
    }

    private func normalizedToolResultText(_ value: Any) -> String {
        if let dict = value as? [String: Any], isStatusOnlyCompletionMarker(dict) {
            return ""
        }
        if let raw = value as? String,
           let data = raw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let dict = json as? [String: Any],
           isStatusOnlyCompletionMarker(dict) {
            return ""
        }
        return stringifyValue(value) ?? ""
    }

    private func isStatusOnlyCompletionMarker(_ dict: [String: Any]) -> Bool {
        let allowedKeys: Set<String> = ["status", "content", "message"]
        let keys = Set(dict.keys)
        guard keys.isSubset(of: allowedKeys) else {
            return false
        }

        guard let rawStatus = dict["status"] as? String else {
            return false
        }
        let status = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["completed", "complete", "done", "success"].contains(status) else {
            return false
        }

        let content = (dict["content"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let message = (dict["message"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return content.isEmpty && message.isEmpty
    }

    private func extractToolKindCandidate(from payload: [String: Any]) -> String? {
        let candidates = [
            payload["toolKind"] as? String,
            payload["tool_kind"] as? String,
            payload["kind"] as? String
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            return normalizeToolName(trimmed)
        }

        return nil
    }

    private func resolveToolUseName(
        from payload: [String: Any],
        fallbackName: String,
        normalizedInput: Any?
    ) -> String {
        if let toolKind = extractToolKindCandidate(from: payload) {
            let loweredFallback = fallbackName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if loweredFallback == "tool" || loweredFallback == "unknown" || CLIToolSemantics.isFileEditName(toolKind) {
                return toolKind
            }
        }

        if CLIToolSemantics.isCommandLikeName(fallbackName) {
            var detectorPayload = payload
            if let normalizedInput {
                detectorPayload["toolInput"] = normalizedInput
                detectorPayload["input"] = normalizedInput
            }
            if codexFileChangePayload(from: detectorPayload) != nil {
                return normalizeToolName("file-edit")
            }
        }

        return fallbackName
    }

    private func extractToolNameCandidate(from payload: [String: Any]) -> String? {
        func readName(from dict: [String: Any]) -> String? {
            let candidate = (dict["toolName"] as? String)
                ?? (dict["name"] as? String)
                ?? (dict["tool"] as? String)
            guard let candidate else { return nil }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return normalizeToolName(trimmed)
        }

        let fileEditCanonical = normalizeToolName("file-edit")

        if let direct = readName(from: payload) {
            if CLIToolSemantics.isCommandLikeName(direct),
               codexFileChangePayload(from: payload) != nil {
                return fileEditCanonical
            }
            return direct
        }
        if let nested = payload["toolResult"] as? [String: Any],
           let name = readName(from: nested) {
            if CLIToolSemantics.isCommandLikeName(name),
               codexFileChangePayload(from: payload) != nil {
                return fileEditCanonical
            }
            return name
        }
        if let nested = payload["result"] as? [String: Any],
           let name = readName(from: nested) {
            if CLIToolSemantics.isCommandLikeName(name),
               codexFileChangePayload(from: payload) != nil {
                return fileEditCanonical
            }
            return name
        }
        if let nested = payload["output"] as? [String: Any],
           let name = readName(from: nested) {
            if CLIToolSemantics.isCommandLikeName(name),
               codexFileChangePayload(from: payload) != nil {
                return fileEditCanonical
            }
            return name
        }
        if let nested = payload["rawOutput"] as? [String: Any],
           let name = readName(from: nested) {
            if CLIToolSemantics.isCommandLikeName(name),
               codexFileChangePayload(from: payload) != nil {
                return fileEditCanonical
            }
            return name
        }

        if let kind = extractToolKindCandidate(from: payload) {
            return kind
        }

        return nil
    }

    func codexFileChangePayload(from payload: [String: Any]) -> Any? {
        let candidates: [Any?] = [
            payload["changes"],
            payload["result"],
            payload["toolResult"],
            payload["output"],
            payload["commandActions"],
            payload["aggregatedOutput"],
            payload
        ]

        for candidate in candidates {
            if isLikelyCodexFileChangePayload(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func isLikelyCodexFileChangePayload(_ value: Any?, depth: Int = 0) -> Bool {
        guard depth <= 4, let value else { return false }

        if let dict = value as? [String: Any] {
            if dict["changes"] != nil && hasUnifiedDiff(in: dict["changes"]) {
                return true
            }
            if hasUnifiedDiff(in: dict) {
                return true
            }
            for nested in dict.values where isLikelyCodexFileChangePayload(nested, depth: depth + 1) {
                return true
            }
            return false
        }

        if let array = value as? [Any] {
            for item in array where isLikelyCodexFileChangePayload(item, depth: depth + 1) {
                return true
            }
            return false
        }

        if let raw = value as? String {
            let lowered = raw.lowercased()
            if lowered.contains("\"unified_diff\"") {
                return true
            }
            if lowered.contains("\"diff\"")
                && (lowered.contains("+++")
                    || lowered.contains("---")
                    || lowered.contains("@@")
                    || lowered.contains("*** begin patch")) {
                return true
            }
            if let data = raw.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) {
                return isLikelyCodexFileChangePayload(json, depth: depth + 1)
            }
        }

        return false
    }

    private func hasUnifiedDiff(in value: Any?) -> Bool {
        guard let value else { return false }

        if let dict = value as? [String: Any] {
            if let unifiedDiff = dict["unified_diff"] as? String,
               !unifiedDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            if let unifiedDiff = dict["unifiedDiff"] as? String,
               !unifiedDiff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            if let diff = dict["diff"] as? String,
               !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
            for nested in dict.values where hasUnifiedDiff(in: nested) {
                return true
            }
            return false
        }

        if let array = value as? [Any] {
            for item in array where hasUnifiedDiff(in: item) {
                return true
            }
            return false
        }

        if let raw = value as? String {
            return raw.lowercased().contains("\"unified_diff\"")
        }

        return false
    }

    private func attachRunContext(_ block: inout [String: Any], uuid: String?, parentUUID: String?) {
        if let uuid, !uuid.isEmpty {
            block["uuid"] = uuid
        }
        if let parentUUID, !parentUUID.isEmpty {
            block["parentUUID"] = parentUUID
        }
    }

    func normalizeToolName(_ name: String) -> String {
        CLIToolSemantics.canonicalToolName(name)
    }

    private func preferredToolInputPayload(from payload: [String: Any]) -> Any? {
        if let toolInput = payload["toolInput"] {
            return toolInput
        }
        if let rawInput = payload["rawInput"] {
            return rawInput
        }
        if let toolArgs = payload["toolArgs"] {
            return toolArgs
        }
        if let input = payload["input"] {
            return input
        }
        if let arguments = payload["arguments"] {
            return arguments
        }
        if let args = payload["args"] {
            return args
        }
        if let params = payload["params"] {
            return params
        }
        if let parameters = payload["parameters"] {
            return parameters
        }
        if let nestedPayload = payload["payload"] {
            return nestedPayload
        }
        if let contentObject = payload["content"] as? [String: Any], !contentObject.isEmpty {
            return contentObject
        }
        if let contentList = payload["content"] as? [Any], !contentList.isEmpty {
            return contentList
        }
        return nil
    }

    private func normalizeToolInput(toolName: String, input: Any?) -> Any? {
        guard toolName == "Bash",
              var dict = input as? [String: Any] else {
            return input
        }

        if let commands = dict["command"] as? [String] {
            dict["command"] = commands.joined(separator: " ")
        }

        if var parsedCommands = dict["parsed_cmd"] as? [[String: Any]] {
            for index in parsedCommands.indices {
                let type = (parsedCommands[index]["type"] as? String)?.lowercased()
                if type == "other" || type == "unknown" {
                    parsedCommands[index]["type"] = "bash"
                }
            }
            dict["parsed_cmd"] = parsedCommands
        }

        return dict
    }

    private func sanitizeToolDescription(from input: Any?) -> String? {
        guard let dict = input as? [String: Any],
              let raw = dict["description"] as? String else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.range(of: #"^\[Pasted ~\d+ lines\]$"#, options: .regularExpression) != nil {
            return nil
        }
        return trimmed
    }

    private func parsePermissionPayload(_ raw: Any?) -> [String: Any]? {
        let dict: [String: Any]? = {
            if let dict = raw as? [String: Any] {
                return dict
            }
            if let rawString = raw as? String,
               let data = rawString.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data),
               let dict = json as? [String: Any] {
                return dict
            }
            return nil
        }()
        guard let dict else { return nil }

        func normalizedStatus(from value: Any?) -> String? {
            guard let raw = (value as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !raw.isEmpty else {
                return nil
            }
            if ["approved", "allow", "allowed", "proceed_once", "proceed_always", "approved_for_session"].contains(raw) {
                return "approved"
            }
            if ["denied", "deny", "reject", "rejected"].contains(raw) {
                return "denied"
            }
            if ["canceled", "cancelled", "cancel", "abort", "aborted"].contains(raw) {
                return "canceled"
            }
            if ["pending", "asked"].contains(raw) {
                return "pending"
            }
            return raw
        }

        var parsed: [String: Any] = [:]

        if let id = firstNonEmptyString([
            dict["id"] as? String,
            dict["requestID"] as? String,
            dict["requestId"] as? String,
            dict["permissionId"] as? String
        ]) {
            parsed["id"] = id
        }

        if let status = normalizedStatus(from: dict["status"]) {
            parsed["status"] = status
        } else if let status = normalizedStatus(from: dict["result"]) {
            parsed["status"] = status
        } else if let status = normalizedStatus(from: dict["reply"]) {
            parsed["status"] = status
        } else if let status = normalizedStatus(from: dict["decision"]) {
            parsed["status"] = status
        }

        if let reason = firstNonEmptyString([
            dict["reason"] as? String,
            dict["message"] as? String
        ]) {
            parsed["reason"] = reason
        }
        if let mode = dict["mode"] as? String, !mode.isEmpty {
            parsed["mode"] = mode
        }
        if let allowedTools = dict["allowedTools"] as? [String], !allowedTools.isEmpty {
            parsed["allowedTools"] = allowedTools
        } else if let allowedTools = dict["allowTools"] as? [String], !allowedTools.isEmpty {
            parsed["allowedTools"] = allowedTools
        }
        if let decision = firstNonEmptyString([
            dict["decision"] as? String,
            dict["reply"] as? String
        ]) {
            parsed["decision"] = decision
        }
        if let dateValue = parseMilliseconds(dict["date"])
            ?? parseMilliseconds(dict["completedAt"])
            ?? parseMilliseconds(dict["updatedAt"])
            ?? parseMilliseconds(dict["timestamp"])
            ?? parseMilliseconds(dict["ts"]) {
            parsed["date"] = dateValue
        }

        return parsed.isEmpty ? nil : parsed
    }

    // MARK: - Session decode helpers

    private func decodeSession(_ raw: [String: Any]) -> CLISession? {
        guard let sessionId = raw["id"] as? String else {
            return nil
        }

        let prefersDataKey: Bool
        if let encryptedDataKey = raw["dataEncryptionKey"] as? String,
           let encryption,
           encryption.initializeResource(resourceId: sessionId, encryptedDataKeyBase64: encryptedDataKey) {
            prefersDataKey = true
        } else {
            prefersDataKey = false
        }
        sessionUsesDataKey[sessionId] = prefersDataKey

        var resolvedPrefersDataKey = prefersDataKey
        var metadataObject = decodeEncryptedObject(
            encrypted: raw["metadata"],
            resourceId: sessionId,
            prefersDataKey: prefersDataKey
        ) as? [String: Any]

        var agentStateObject = decodeEncryptedObject(
            encrypted: raw["agentState"],
            resourceId: sessionId,
            prefersDataKey: prefersDataKey
        ) as? [String: Any]

        if metadataObject == nil && agentStateObject == nil {
            let fallbackMode = !prefersDataKey
            let fallbackMetadata = decodeEncryptedObject(
                encrypted: raw["metadata"],
                resourceId: sessionId,
                prefersDataKey: fallbackMode
            ) as? [String: Any]
            let fallbackAgentState = decodeEncryptedObject(
                encrypted: raw["agentState"],
                resourceId: sessionId,
                prefersDataKey: fallbackMode
            ) as? [String: Any]

            if fallbackMetadata != nil || fallbackAgentState != nil {
                resolvedPrefersDataKey = fallbackMode
                metadataObject = fallbackMetadata
                agentStateObject = fallbackAgentState
            }
        }

        sessionUsesDataKey[sessionId] = resolvedPrefersDataKey

        let seq = raw["seq"] as? Int ?? 0
        sessionLastSeq[sessionId] = max(sessionLastSeq[sessionId] ?? 0, seq)

        return CLISession(
            id: sessionId,
            seq: seq,
            createdAt: parseDate(raw["createdAt"]) ?? Date(),
            updatedAt: parseDate(raw["updatedAt"]) ?? Date(),
            active: raw["active"] as? Bool ?? false,
            activeAt: parseDate(raw["activeAt"]) ?? Date(),
            metadata: decodeMetadata(from: metadataObject),
            agentState: decodeAgentState(from: agentStateObject),
            agentStateVersion: raw["agentStateVersion"] as? Int ?? 0
        )
    }

    private func decodeMetadata(from value: [String: Any]?) -> CLISession.Metadata? {
        guard let value else { return nil }

        guard let path = value["path"] as? String,
              !path.isEmpty else {
            return nil
        }

        let host = (value["host"] as? String) ?? "Unknown"
        let machineId = (value["machineId"] as? String) ?? ""
        let hostPid = parseInt(value["hostPid"])
        let flavor = value["flavor"] as? String
        let homeDir = (value["homeDir"] as? String) ?? ""
        let version = (value["version"] as? String) ?? "unknown"
        let platform = value["platform"] as? String

        let customTitle = (value["customTitle"] as? String) ?? (value["name"] as? String)

        var summary: CLISession.Metadata.Summary?
        if let summaryRaw = value["summary"] as? [String: Any],
           let text = summaryRaw["text"] as? String,
           !text.isEmpty {
            summary = CLISession.Metadata.Summary(
                text: text,
                updatedAt: parseDate(summaryRaw["updatedAt"]) ?? Date()
            )
        }

        var gitStatus: CLISession.Metadata.GitStatus?
        if let gitRaw = value["gitStatus"] as? [String: Any] {
            gitStatus = CLISession.Metadata.GitStatus(
                branch: gitRaw["branch"] as? String,
                isDirty: gitRaw["isDirty"] as? Bool,
                changedFiles: parseInt(
                    gitRaw["changedFiles"]
                    ?? gitRaw["filesChanged"]
                    ?? gitRaw["files"]
                ),
                addedLines: parseInt(
                    gitRaw["addedLines"]
                    ?? gitRaw["added"]
                    ?? gitRaw["insertions"]
                    ?? gitRaw["additions"]
                ),
                deletedLines: parseInt(
                    gitRaw["deletedLines"]
                    ?? gitRaw["deleted"]
                    ?? gitRaw["deletions"]
                    ?? gitRaw["removals"]
                ),
                upstreamBranch: (gitRaw["upstreamBranch"] as? String) ?? (gitRaw["upstream"] as? String),
                aheadCount: parseInt(gitRaw["aheadCount"] ?? gitRaw["ahead"]),
                behindCount: parseInt(gitRaw["behindCount"] ?? gitRaw["behind"])
            )
        }

        var runtime: CLISession.Metadata.Runtime?
        if let runtimeRaw = value["runtime"] as? [String: Any] {
            runtime = CLISession.Metadata.Runtime(
                provider: runtimeRaw["provider"] as? String,
                agentVersion: runtimeRaw["agentVersion"] as? String,
                status: runtimeRaw["status"] as? String,
                statusDetail: runtimeRaw["statusDetail"] as? String,
                permissionMode: runtimeRaw["permissionMode"] as? String,
                permissionModeLabel: runtimeRaw["permissionModeLabel"] as? String,
                reasoningEffort: runtimeRaw["reasoningEffort"] as? String,
                reasoningEffortLabel: runtimeRaw["reasoningEffortLabel"] as? String,
                supportedReasoningEfforts: runtimeRaw["supportedReasoningEfforts"] as? [String],
                opencodeModeId: runtimeRaw["opencodeModeId"] as? String,
                opencodeModeLabel: runtimeRaw["opencodeModeLabel"] as? String,
                opencodeModelId: runtimeRaw["opencodeModelId"] as? String,
                opencodeVariant: runtimeRaw["opencodeVariant"] as? String,
                opencodeAvailableVariants: runtimeRaw["opencodeAvailableVariants"] as? [String],
                model: runtimeRaw["model"] as? String,
                contextSize: parseInt(runtimeRaw["contextSize"]),
                contextWindow: parseInt(runtimeRaw["contextWindow"]),
                contextRemainingPercent: parseDouble(runtimeRaw["contextRemainingPercent"]),
                mcpReady: runtimeRaw["mcpReady"] as? [String],
                mcpFailed: runtimeRaw["mcpFailed"] as? [String],
                mcpCancelled: runtimeRaw["mcpCancelled"] as? [String],
                mcpToolNames: runtimeRaw["mcpToolNames"] as? [String],
                mcpStartupPhase: runtimeRaw["mcpStartupPhase"] as? String,
                mcpStartupUpdatedAt: parseDate(runtimeRaw["mcpStartupUpdatedAt"]),
                skillAvailableCount: parseInt(runtimeRaw["skillAvailableCount"]),
                skillLoadedCount: parseInt(runtimeRaw["skillLoadedCount"]),
                skillLoadedUris: parseStringList(runtimeRaw["skillLoadedUris"] ?? runtimeRaw["loadedSkillUris"]),
                skillLoadState: runtimeRaw["skillLoadState"] as? String,
                skillLastSyncAt: parseDate(runtimeRaw["skillLastSyncAt"]),
                skillLastError: runtimeRaw["skillLastError"] as? String,
                skills: parseRuntimeSkills(runtimeRaw["skills"]),
                updatedAt: parseDate(runtimeRaw["updatedAt"]),
                titleStatus: runtimeRaw["titleStatus"] as? String,
                titleSource: runtimeRaw["titleSource"] as? String,
                titleUpdatedAt: parseDate(runtimeRaw["titleUpdatedAt"]),
                titleLastError: runtimeRaw["titleLastError"] as? String
            )
        }

        return CLISession.Metadata(
            path: path,
            host: host,
            machineId: machineId,
            hostPid: hostPid,
            flavor: flavor,
            homeDir: homeDir,
            version: version,
            platform: platform,
            runtime: runtime,
            claudeSessionId: value["claudeSessionId"] as? String,
            codexSessionId: value["codexSessionId"] as? String,
            opencodeSessionId: value["opencodeSessionId"] as? String,
            geminiSessionId: value["geminiSessionId"] as? String,
            customTitle: customTitle,
            summary: summary,
            gitStatus: gitStatus
        )
    }

    private func decodeAgentState(from value: [String: Any]?) -> CLISession.AgentState? {
        guard let value else { return nil }

        let status: CLISession.AgentState.Status
        let requests = decodePendingPermissionRequests(from: value["requests"])
        let completedRequests = decodeCompletedPermissionRequests(from: value["completedRequests"])

        if let rawStatus = (value["status"] as? String)?.lowercased() {
            switch rawStatus {
            case "thinking":
                status = .thinking
            case "waiting_for_permission":
                status = .waitingForPermission
            case "error":
                status = .error
            default:
                status = .idle
            }
        } else if (value["thinking"] as? Bool) == true {
            status = .thinking
        } else if let requests, !requests.isEmpty {
            status = .waitingForPermission
        } else {
            status = .idle
        }

        return CLISession.AgentState(
            status: status,
            message: value["message"] as? String,
            requests: requests,
            completedRequests: completedRequests
        )
    }

    private func decodePendingPermissionRequests(
        from raw: Any?
    ) -> [String: CLISession.AgentState.PermissionRequest]? {
        guard let dict = raw as? [String: Any], !dict.isEmpty else {
            return nil
        }

        var result: [String: CLISession.AgentState.PermissionRequest] = [:]
        for (id, value) in dict {
            guard let request = value as? [String: Any] else { continue }
            let tool = request["tool"] as? String ?? "tool"
            let arguments = stringifyValue(request["arguments"])
            let createdAt = parseDate(request["createdAt"])
            result[id] = CLISession.AgentState.PermissionRequest(
                tool: tool,
                arguments: arguments,
                createdAt: createdAt
            )
        }

        return result.isEmpty ? nil : result
    }

    private func decodeCompletedPermissionRequests(
        from raw: Any?
    ) -> [String: CLISession.AgentState.CompletedPermissionRequest]? {
        guard let dict = raw as? [String: Any], !dict.isEmpty else {
            return nil
        }

        var result: [String: CLISession.AgentState.CompletedPermissionRequest] = [:]
        for (id, value) in dict {
            guard let completed = value as? [String: Any] else { continue }
            let tool = completed["tool"] as? String ?? "tool"
            let arguments = stringifyValue(completed["arguments"])
            let createdAt = parseDate(completed["createdAt"])
            let completedAt = parseDate(completed["completedAt"])
            let status = (completed["status"] as? String) ?? "approved"
            let reason = completed["reason"] as? String
            let mode = completed["mode"] as? String
            let allowedTools = completed["allowedTools"] as? [String]
            let decision = completed["decision"] as? String

            result[id] = CLISession.AgentState.CompletedPermissionRequest(
                tool: tool,
                arguments: arguments,
                createdAt: createdAt,
                completedAt: completedAt,
                status: status,
                reason: reason,
                mode: mode,
                allowedTools: allowedTools,
                decision: decision
            )
        }

        return result.isEmpty ? nil : result
    }

    private func buildChannelMetadata(from session: CLISession, agentId: String) -> [String: Any] {
        var metadata: [String: Any] = [
            "cliSessionId": session.id,
            "sessionUri": SessionStorageLayout.sessionResourceURI(agentId: agentId, sessionId: session.id),
            "seq": session.seq,
            "agentStateVersion": session.agentStateVersion
        ]

        if let meta = session.metadata {
            metadata["path"] = meta.path
            metadata["pathBasename"] = meta.pathBasename
            metadata["machineId"] = meta.machineId
            metadata["host"] = meta.host
            metadata["hostPid"] = meta.hostPid as Any
            metadata["flavor"] = meta.flavor as Any
            metadata["homeDir"] = meta.homeDir
            metadata["claudeSessionId"] = meta.claudeSessionId as Any
            metadata["codexSessionId"] = meta.codexSessionId as Any
            metadata["opencodeSessionId"] = meta.opencodeSessionId as Any
            metadata["geminiSessionId"] = meta.geminiSessionId as Any
            metadata["customTitle"] = meta.customTitle as Any
            if let runtimeObject = runtimeJSON(meta.runtime) {
                metadata["runtime"] = runtimeObject
            }

            if let summary = meta.summary {
                metadata["summary"] = [
                    "text": summary.text,
                    "updatedAt": Int64(summary.updatedAt.timeIntervalSince1970 * 1000)
                ]
            }

            if let gitStatus = meta.gitStatus {
                metadata["gitStatus"] = [
                    "branch": gitStatus.branch as Any,
                    "isDirty": gitStatus.isDirty as Any,
                    "changedFiles": gitStatus.changedFiles as Any,
                    "addedLines": gitStatus.addedLines as Any,
                    "deletedLines": gitStatus.deletedLines as Any,
                    "upstreamBranch": gitStatus.upstreamBranch as Any,
                    "aheadCount": gitStatus.aheadCount as Any,
                    "behindCount": gitStatus.behindCount as Any
                ]
            }

            if let rawData = try? JSONSerialization.data(withJSONObject: metadataJSON(meta)),
               let rawJSON = String(data: rawData, encoding: .utf8) {
                metadata["rawJSON"] = rawJSON
            }
        }

        return metadata
    }

    private func metadataJSON(_ metadata: CLISession.Metadata) -> [String: Any] {
        var value: [String: Any] = [
            "path": metadata.path,
            "host": metadata.host,
            "machineId": metadata.machineId,
            "homeDir": metadata.homeDir,
            "version": metadata.version
        ]

        value["hostPid"] = metadata.hostPid as Any
        value["flavor"] = metadata.flavor as Any
        value["platform"] = metadata.platform as Any
        value["claudeSessionId"] = metadata.claudeSessionId as Any
        value["codexSessionId"] = metadata.codexSessionId as Any
        value["opencodeSessionId"] = metadata.opencodeSessionId as Any
        value["geminiSessionId"] = metadata.geminiSessionId as Any
        value["customTitle"] = metadata.customTitle as Any
        if let runtimeObject = runtimeJSON(metadata.runtime) {
            value["runtime"] = runtimeObject
        }

        if let summary = metadata.summary {
            value["summary"] = [
                "text": summary.text,
                "updatedAt": Int64(summary.updatedAt.timeIntervalSince1970 * 1000)
            ]
        }

        if let gitStatus = metadata.gitStatus {
            value["gitStatus"] = [
                "branch": gitStatus.branch as Any,
                "isDirty": gitStatus.isDirty as Any,
                "changedFiles": gitStatus.changedFiles as Any,
                "addedLines": gitStatus.addedLines as Any,
                "deletedLines": gitStatus.deletedLines as Any,
                "upstreamBranch": gitStatus.upstreamBranch as Any,
                "aheadCount": gitStatus.aheadCount as Any,
                "behindCount": gitStatus.behindCount as Any
            ]
        }

        return value
    }

    private func buildTags(flavor: String?) -> [String] {
        var tags = ["cli"]
        switch flavor?.lowercased() {
        case "codex":
            tags.append("codex")
        case "opencode":
            tags.append("opencode")
        case "gemini":
            tags.append("gemini")
        default:
            tags.append("claude-code")
        }
        return tags
    }

    private func runtimeJSON(_ runtime: CLISession.Metadata.Runtime?) -> [String: Any]? {
        guard let runtime else { return nil }
        var value: [String: Any] = [:]
        if let provider = runtime.provider { value["provider"] = provider }
        if let agentVersion = runtime.agentVersion { value["agentVersion"] = agentVersion }
        if let status = runtime.status { value["status"] = status }
        if let statusDetail = runtime.statusDetail { value["statusDetail"] = statusDetail }
        if let model = runtime.model { value["model"] = model }
        if let contextSize = runtime.contextSize { value["contextSize"] = contextSize }
        if let contextWindow = runtime.contextWindow { value["contextWindow"] = contextWindow }
        if let contextRemainingPercent = runtime.contextRemainingPercent {
            value["contextRemainingPercent"] = contextRemainingPercent
        }
        if let mcpReady = runtime.mcpReady { value["mcpReady"] = mcpReady }
        if let mcpFailed = runtime.mcpFailed { value["mcpFailed"] = mcpFailed }
        if let mcpCancelled = runtime.mcpCancelled { value["mcpCancelled"] = mcpCancelled }
        if let mcpToolNames = runtime.mcpToolNames { value["mcpToolNames"] = mcpToolNames }
        if let mcpStartupPhase = runtime.mcpStartupPhase { value["mcpStartupPhase"] = mcpStartupPhase }
        if let mcpStartupUpdatedAt = runtime.mcpStartupUpdatedAt {
            value["mcpStartupUpdatedAt"] = Int64(mcpStartupUpdatedAt.timeIntervalSince1970 * 1000)
        }
        if let skillAvailableCount = runtime.skillAvailableCount { value["skillAvailableCount"] = skillAvailableCount }
        if let skillLoadedCount = runtime.skillLoadedCount { value["skillLoadedCount"] = skillLoadedCount }
        if let skillLoadedUris = runtime.skillLoadedUris { value["skillLoadedUris"] = skillLoadedUris }
        if let skillLoadState = runtime.skillLoadState { value["skillLoadState"] = skillLoadState }
        if let skillLastSyncAt = runtime.skillLastSyncAt {
            value["skillLastSyncAt"] = Int64(skillLastSyncAt.timeIntervalSince1970 * 1000)
        }
        if let skillLastError = runtime.skillLastError { value["skillLastError"] = skillLastError }
        if let skills = runtime.skills {
            value["skills"] = skills.map { skill in
                var item: [String: Any] = [
                    "skillUri": skill.skillUri
                ]
                if let name = skill.name { item["name"] = name }
                if let scope = skill.scope { item["scope"] = scope }
                if let type = skill.type { item["type"] = type }
                if let spaceId = skill.spaceId { item["spaceId"] = spaceId }
                if let isLoaded = skill.isLoaded { item["isLoaded"] = isLoaded }
                if let lastLoadedAt = skill.lastLoadedAt {
                    item["lastLoadedAt"] = Int64(lastLoadedAt.timeIntervalSince1970 * 1000)
                }
                return item
            }
        }
        if let updatedAt = runtime.updatedAt {
            value["updatedAt"] = Int64(updatedAt.timeIntervalSince1970 * 1000)
        }
        if let titleStatus = runtime.titleStatus { value["titleStatus"] = titleStatus }
        if let titleSource = runtime.titleSource { value["titleSource"] = titleSource }
        if let titleUpdatedAt = runtime.titleUpdatedAt {
            value["titleUpdatedAt"] = Int64(titleUpdatedAt.timeIntervalSince1970 * 1000)
        }
        if let titleLastError = runtime.titleLastError { value["titleLastError"] = titleLastError }
        return value.isEmpty ? nil : value
    }

    // MARK: - HTTP helpers

    private func authorizedRequest(path: String, method: String = "GET") async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents(url: serverURL, resolvingAgainstBaseURL: false)
        var normalized = path.hasPrefix("/") ? path : "/\(path)"

        // Backward-compatible guard: some callers may pass an already percent-encoded '?'
        // (e.g. ".../messages%3Flimit=150"). Convert first separator back to query delimiter.
        if !normalized.contains("?"),
           let encodedQuerySeparator = normalized.range(of: "%3F", options: [.caseInsensitive]) {
            normalized.replaceSubrange(encodedQuerySeparator, with: "?")
        }

        if let querySeparator = normalized.firstIndex(of: "?") {
            let pathPart = String(normalized[..<querySeparator])
            let queryPart = String(normalized[normalized.index(after: querySeparator)...])
            components?.path = pathPart
            components?.percentEncodedQuery = queryPart.isEmpty ? nil : queryPart
        } else {
            components?.path = normalized
            components?.percentEncodedQuery = nil
        }

        guard let url = components?.url else {
            throw RPCError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RPCError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
            throw RPCError.serverError(message)
        }

        return (data, httpResponse)
    }

    // MARK: - Decryption helpers

    private func decodeEncryptedObject(encrypted: Any?, resourceId: String, prefersDataKey: Bool) -> Any? {
        if let dict = encrypted as? [String: Any] {
            return dict
        }

        guard let encryptedString = encrypted as? String else {
            return nil
        }

        if let encryption,
           let decrypted = encryption.decryptJSONObject(base64String: encryptedString, resourceId: resourceId, prefersDataKey: prefersDataKey) {
            return decrypted
        }

        return nil
    }

    // MARK: - Value parsers

    func parseInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double { return doubleValue }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private func parseMilliseconds(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double { return doubleValue }
        if let intValue = value as? Int { return Double(intValue) }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String, let parsed = Double(string) { return parsed }
        return nil
    }

    private func parseDate(_ value: Any?) -> Date? {
        guard let millis = parseMilliseconds(value) else {
            return nil
        }

        if millis > 1_000_000_000_000 {
            return Date(timeIntervalSince1970: millis / 1000.0)
        }

        if millis > 10_000_000_000 {
            return Date(timeIntervalSince1970: millis / 1000.0)
        }

        return Date(timeIntervalSince1970: millis)
    }

    private func parseStringList(_ value: Any?) -> [String] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            guard let text = item as? String else { return nil }
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private func parseDictionary(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            return dict
        }
        if let bridged = value as? [AnyHashable: Any] {
            return Dictionary(uniqueKeysWithValues: bridged.compactMap { entry in
                guard let key = entry.key as? String else { return nil }
                return (key, entry.value)
            })
        }
        return nil
    }

    private func parseSkillString(_ value: Any?) -> String? {
        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        if let dict = parseDictionary(value) {
            return firstNonEmptySkillString([
                dict["text"],
                dict["value"],
                dict["name"],
                dict["title"],
                dict["description"],
                dict["summary"]
            ])
        }
        return nil
    }

    private func firstNonEmptySkillString(_ values: [Any?]) -> String? {
        for value in values {
            if let normalized = parseSkillString(value) {
                return normalized
            }
        }
        return nil
    }

    private func parseSkillBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) { return true }
            if ["false", "0", "no", "n"].contains(normalized) { return false }
        }
        return nil
    }

    private func parseRuntimeSkill(_ value: Any?) -> CLISession.Metadata.Runtime.Skill? {
        guard let dict = value as? [String: Any] else { return nil }
        let nested = parseDictionary(dict["skill"])
            ?? parseDictionary(dict["metadata"])
            ?? parseDictionary(dict["data"])
        let uri = firstNonEmptySkillString([
            dict["skillUri"],
            dict["skillURI"],
            dict["skill_uri"],
            dict["uri"],
            nested?["skillUri"],
            nested?["skillURI"],
            nested?["skill_uri"],
            nested?["uri"]
        ])
        guard let uri, !uri.isEmpty else { return nil }

        let name = firstNonEmptySkillString([
            dict["name"],
            dict["displayName"],
            dict["skillName"],
            dict["title"],
            nested?["name"],
            nested?["displayName"],
            nested?["skillName"],
            nested?["title"]
        ])
        let description = firstNonEmptySkillString([
            dict["description"],
            dict["desc"],
            dict["summary"],
            dict["detail"],
            dict["promptTemplate"],
            nested?["description"],
            nested?["desc"],
            nested?["summary"],
            nested?["detail"],
            nested?["promptTemplate"]
        ])
        let scope = firstNonEmptySkillString([
            dict["scope"],
            nested?["scope"]
        ])
        let type = firstNonEmptySkillString([
            dict["type"],
            nested?["type"]
        ])
        let spaceId = firstNonEmptySkillString([
            dict["spaceId"],
            dict["spaceID"],
            nested?["spaceId"],
            nested?["spaceID"]
        ])

        return CLISession.Metadata.Runtime.Skill(
            skillUri: uri,
            name: (name?.isEmpty == false) ? name : nil,
            description: (description?.isEmpty == false) ? description : nil,
            scope: (scope?.isEmpty == false) ? scope : nil,
            type: (type?.isEmpty == false) ? type : nil,
            spaceId: (spaceId?.isEmpty == false) ? spaceId : nil,
            isSystem: parseSkillBool(dict["isSystem"]) ?? parseSkillBool(nested?["isSystem"]),
            isLoaded: dict["isLoaded"] as? Bool,
            lastLoadedAt: parseDate(dict["lastLoadedAt"])
        )
    }

    private func parseRuntimeSkills(_ value: Any?) -> [CLISession.Metadata.Runtime.Skill]? {
        guard let items = value as? [Any] else { return nil }
        let parsed = items.compactMap(parseRuntimeSkill)
        return parsed.isEmpty ? nil : parsed
    }

    func stringifyValue(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let text = value as? String {
            return text
        }

        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return String(describing: value)
    }

    // MARK: - WebSocket I/O

    private func send(text: String) {
        let message = URLSessionWebSocketTask.Message.string(text)
        webSocket?.send(message) { [weak self] error in
            guard let self, let error else { return }
            Task { @MainActor in
                self.handleSendFailure(error, payloadPreview: text)
            }
        }
    }

    private func sendAwaitingDelivery(text: String) async throws {
        guard let webSocket else {
            throw RPCError.notConnected
        }

        let message = URLSessionWebSocketTask.Message.string(text)
        do {
            try await webSocket.send(message)
        } catch {
            handleSendFailure(error, payloadPreview: text)
            throw RPCError.serverError(error.localizedDescription)
        }
    }

    private func emitSocketEvent(_ eventName: String, payload: [String: Any]) async throws {
        guard let eventData = try? JSONSerialization.data(withJSONObject: [eventName, payload]),
              let eventJSON = String(data: eventData, encoding: .utf8) else {
            throw RPCError.encodeFailed
        }
        try await sendAwaitingDelivery(text: "42" + eventJSON)
    }

    private func ensureConnected(timeout: TimeInterval = 8.0) async throws {
        if isConnected, webSocket != nil {
            return
        }

        if connectionState == .disconnected || webSocket == nil {
            connect()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isConnected, webSocket != nil {
                return
            }

            if case .error(let message) = connectionState {
                throw RPCError.serverError(message)
            }

            try await Task.sleep(nanoseconds: 200_000_000)
        }

        throw RPCError.notConnected
    }

    private func handleSendFailure(_ error: Error, payloadPreview: String) {
        let preview = payloadPreview.prefix(32)
        print("⚠️ [RelayClient] WebSocket send failed (\(preview)...): \(error.localizedDescription)")

        if isConnected || connectionState == .connected || connectionState == .connecting {
            handleConnectionLost()
        }
    }

    private func resolveSessionPrefersDataKey(sessionId: String) async throws -> Bool {
        if let prefersDataKey = sessionUsesDataKey[sessionId] {
            if !prefersDataKey {
                return false
            }
            if let encryption, encryption.hasSessionKey(sessionId) {
                return true
            }
        }

        guard encryption != nil else {
            sessionUsesDataKey[sessionId] = false
            return false
        }

        _ = try await fetchSessions()

        guard let refreshedPrefersDataKey = sessionUsesDataKey[sessionId] else {
            throw RPCError.serverError("Session not found or encryption metadata missing")
        }

        if refreshedPrefersDataKey,
           let encryption,
           !encryption.hasSessionKey(sessionId) {
            throw RPCError.serverError("Session encryption key not ready")
        }

        return refreshedPrefersDataKey
    }

    private func receiveMessage() {
        webSocket?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    Task { @MainActor in
                        self.parseSocketIOMessage(text)
                    }
                case .data:
                    break
                @unknown default:
                    break
                }

                Task { @MainActor in
                    self.receiveMessage()
                }

            case .failure:
                Task { @MainActor in
                    self.handleConnectionLost()
                }
            }
        }
    }

    // MARK: - Reconnection

    private func handleConnectionLost() {
        isConnected = false
        webSocket = nil
        engineIOSid = nil
        stopPingTimer()
        failPendingRPCResponses(with: RPCError.disconnected)

        guard reconnectAttempts < maxReconnectAttempts else {
            connectionState = .error("连接失败，请重试")
            return
        }

        connectionState = .connecting
        reconnectAttempts += 1
        let delay = min(1.0 + Double(reconnectAttempts) * 1.0, 5.0)

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.connectWebSocket()
            }
        }
    }

    // MARK: - Ping/Pong

    private func startPingTimer() {
        stopPingTimer()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.send(text: "2")
            }
        }
    }

    private func stopPingTimer() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func stopReconnectTimer() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    private func failPendingRPCResponses(with error: Error) {
        let pending = pendingRPCResponses
        pendingRPCResponses.removeAll()

        for (_, request) in pending {
            request.timeoutTask.cancel()
            request.continuation.resume(throwing: error)
        }
    }
}
