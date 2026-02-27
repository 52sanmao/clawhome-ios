//
//  CoreAPIClient.swift
//  contextgo
//
//  contextgo-core 服务的 REST API 客户端
//  Base URL 来自 CoreConfig.endpoint，认证使用 JWT Bearer Token
//

import Foundation

/// contextgo-core 专用 API 错误类型
enum CoreAPIError: Error {
    case notConfigured
    case invalidURL
    case invalidResponse
    case unauthorized
    case httpError(Int, String?)
    case decodingError(Error)
    case encodingError(Error)

    var localizedDescription: String {
        switch self {
        case .notConfigured:
            return "Core 未配置，请在设置中填写 Core 地址并登录"
        case .invalidURL:
            return "无效的 URL"
        case .invalidResponse:
            return "无效的服务器响应"
        case .unauthorized:
            return "未登录或 Token 已过期，请重新登录"
        case .httpError(let code, let message):
            return "HTTP \(code)\(message.map { ": \($0)" } ?? "")"
        case .decodingError(let error):
            return "数据解析错误: \(error.localizedDescription)"
        case .encodingError(let error):
            return "数据编码错误: \(error.localizedDescription)"
        }
    }
}

/// 通用 Core API 响应包装
struct CoreAPIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: String?
}

/// contextgo-core REST API 客户端（调用本地或私有部署的 core 服务）
@MainActor
class CoreAPIClient {
    static let shared = CoreAPIClient()

    private let config = CoreConfig.shared

    private var baseURL: String {
        var url = config.endpoint.trimmingCharacters(in: .whitespaces)
        if url.hasSuffix("/") { url = String(url.dropLast()) }
        return url
    }

    private var bearerToken: String {
        config.jwtToken
    }

    private init() {}

    // MARK: - Generic Request

    func get<T: Decodable>(_ path: String) async throws -> T {
        return try await request(path, method: "GET", body: EmptyBody?.none)
    }

    func post<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        return try await request(path, method: "POST", body: body)
    }

    func put<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        return try await request(path, method: "PUT", body: body)
    }

    func delete(_ path: String) async throws {
        let _: EmptyResponse = try await request(path, method: "DELETE", body: EmptyBody?.none)
    }

    func uploadAttachment(data: Data, fileName: String, mimeType: String? = nil) async throws -> CoreAttachmentInfo {
        let response: CoreAPIResponse<CoreAttachmentInfo> = try await requestBinary(
            "/api/attachments",
            method: "POST",
            body: data,
            contentType: "application/octet-stream",
            headers: [
                "X-File-Name": fileName,
                "X-Mime-Type": mimeType ?? "application/octet-stream",
            ]
        )
        guard let info = response.data else {
            throw CoreAPIError.httpError(500, response.error ?? "附件上传失败")
        }
        return info
    }

    func getAttachmentURL(attachmentUri: String) async throws -> CoreAttachmentURLData {
        let path = makePath(
            "/api/attachments/url",
            queryItems: [URLQueryItem(name: "attachmentUri", value: attachmentUri)]
        )
        let response: CoreAPIResponse<CoreAttachmentURLData> = try await get(path)
        guard let data = response.data else {
            throw CoreAPIError.httpError(404, response.error ?? "附件不存在")
        }
        return data
    }

    func downloadAttachment(attachmentUri: String, ifSha256: String? = nil) async throws -> CoreAttachmentDownloadData {
        var queryItems = [URLQueryItem(name: "attachmentUri", value: attachmentUri)]
        if let ifSha256, !ifSha256.isEmpty {
            queryItems.append(URLQueryItem(name: "ifSha256", value: ifSha256))
        }
        let path = makePath("/api/attachments/download", queryItems: queryItems)
        let response: CoreAPIResponse<CoreAttachmentDownloadData> = try await get(path)
        guard let data = response.data else {
            throw CoreAPIError.httpError(404, response.error ?? "附件不存在")
        }
        return data
    }

    private func request<T: Decodable, B: Encodable>(
        _ path: String,
        method: String,
        body: B?
    ) async throws -> T {
        guard config.isConfigured else {
            throw CoreAPIError.notConfigured
        }

        guard let url = URL(string: baseURL + path) else {
            throw CoreAPIError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")

        if let body = body {
            do {
                req.httpBody = try JSONEncoder().encode(body)
            } catch {
                throw CoreAPIError.encodingError(error)
            }
        }

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoreAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            if httpResponse.statusCode == 401 {
                throw CoreAPIError.unauthorized
            }
            throw CoreAPIError.httpError(httpResponse.statusCode, message)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CoreAPIError.decodingError(error)
        }
    }

    private func requestBinary<T: Decodable>(
        _ path: String,
        method: String,
        body: Data,
        contentType: String,
        headers: [String: String] = [:]
    ) async throws -> T {
        guard config.isConfigured else {
            throw CoreAPIError.notConfigured
        }

        guard let url = URL(string: baseURL + path) else {
            throw CoreAPIError.invalidURL
        }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CoreAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let message = String(data: data, encoding: .utf8)
            if httpResponse.statusCode == 401 {
                throw CoreAPIError.unauthorized
            }
            throw CoreAPIError.httpError(httpResponse.statusCode, message)
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw CoreAPIError.decodingError(error)
        }
    }

    // MARK: - Health Check

    /// 测试 Core 服务连接（不需要认证）
    func checkHealth() async throws -> Bool {
        guard !baseURL.isEmpty else { throw CoreAPIError.notConfigured }
        guard let url = URL(string: baseURL + "/health") else { throw CoreAPIError.invalidURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: req)
        guard let httpResponse = response as? HTTPURLResponse else { throw CoreAPIError.invalidResponse }
        return httpResponse.statusCode == 200
    }

    // MARK: - Auth API

    func getMe() async throws -> User {
        let response: MeResponse = try await get("/api/auth/me")
        guard let user = response.user else { throw CoreAPIError.unauthorized }
        return user
    }

    // MARK: - Spaces API

    func listSpaces() async throws -> [Space] {
        let response: SpaceListResponse = try await get("/api/spaces")
        return response.data
    }

    func createSpace(displayName: String, name: String? = nil, description: String? = nil) async throws -> Space {
        struct CreateBody: Encodable { let displayName: String; let name: String?; let description: String? }
        let response: SpaceResponse = try await post("/api/spaces", body: CreateBody(displayName: displayName, name: name, description: description))
        guard let space = response.data else {
            throw CoreAPIError.httpError(400, response.error)
        }
        return space
    }

    func deleteSpace(spaceId: String) async throws {
        try await delete("/api/spaces/\(spaceId)")
    }

    // MARK: - Context API

    func createContext(
        ctxUri: String,
        intent: String,
        result: String,
        relations: CoreContextRelations? = nil,
        meta: CoreContextEntryMeta? = nil
    ) async throws -> String {
        struct Body: Encodable {
            let ctxUri: String
            let intent: String
            let result: String
            let relations: CoreContextRelations?
            let meta: CoreContextEntryMeta?
        }
        struct CreateContextResponse: Decodable {
            let entryId: String
            let ctxUri: String?
        }
        let response: CoreAPIResponse<CreateContextResponse> = try await post(
            "/api/contexts",
            body: Body(ctxUri: ctxUri, intent: intent, result: result, relations: relations, meta: meta)
        )
        return response.data?.entryId ?? ""
    }

    func readContext(ctxUri: String, level: String = "detail") async throws -> String {
        struct ReadContextData: Decodable {
            let ctxUri: String
            let content: String
        }

        let path = makePath(
            "/api/contexts",
            queryItems: [
                URLQueryItem(name: "ctxUri", value: ctxUri),
                URLQueryItem(name: "level", value: level),
            ]
        )
        let response: CoreAPIResponse<ReadContextData> = try await get(path)
        return response.data?.content ?? ""
    }

    func searchContexts(
        ctxUri: String,
        query: String? = nil,
        kinds: [String]? = nil,
        statuses: [String]? = nil,
        dateRange: [String]? = nil,
        limit: Int = 200
    ) async throws -> [CoreContextSearchResult] {
        struct Body: Encodable {
            let ctxUri: String
            let query: String?
            let kinds: [String]?
            let statuses: [String]?
            let dateRange: [String]?
            let limit: Int
        }
        struct SearchContextData: Decodable {
            let ctxUri: String
            let results: [CoreContextSearchResult]
        }

        let body = Body(ctxUri: ctxUri, query: query, kinds: kinds, statuses: statuses, dateRange: dateRange, limit: limit)
        let response: CoreAPIResponse<SearchContextData> = try await post("/api/contexts/search", body: body)
        return response.data?.results ?? []
    }

    func getContextEntry(entryId: String) async throws -> CoreContextSearchResult? {
        struct EntryResponse: Decodable {
            let success: Bool
            let data: CoreContextSearchResult?
            let error: String?
        }
        let path = "/api/contexts/entries/\(entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryId)"
        let response: EntryResponse = try await get(path)
        return response.data
    }

    func updateContextEntryStatus(entryId: String, status: String) async throws -> Bool {
        struct Body: Encodable {
            let status: String
        }
        struct UpdateResponse: Decodable {
            let success: Bool
            let data: StatusData?
            let error: String?

            struct StatusData: Decodable {
                let entryId: String
                let status: String
            }
        }
        let path = "/api/contexts/entries/\(entryId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entryId)/status"
        let response: UpdateResponse = try await request(path, method: "PATCH", body: Body(status: status))
        return response.success
    }

    // MARK: - Task API

    func listTasks(spaceUri: String) async throws -> [SpaceTask] {
        struct TasksResponse: Decodable { let success: Bool; let data: [SpaceTask] }
        let path = makePath(
            "/api/tasks",
            queryItems: [URLQueryItem(name: "spaceUri", value: spaceUri)]
        )
        let response: TasksResponse = try await get(path)
        return response.data
    }

    // MARK: - Skill API

    func listSkills(spaceUri: String) async throws -> [SpaceSkill] {
        struct SkillsResponse: Decodable { let success: Bool; let data: [SpaceSkill] }
        let path = makePath(
            "/api/skills",
            queryItems: [URLQueryItem(name: "spaceUri", value: spaceUri)]
        )
        let response: SkillsResponse = try await get(path)
        return response.data
    }

    // MARK: - Agent API

    func listAgents() async throws -> [CloudAgent] {
        struct AgentsResponse: Decodable { let success: Bool; let data: [CloudAgent] }
        let response: AgentsResponse = try await get("/api/agents")
        return response.data
    }

    func getAgent(id: String) async throws -> CloudAgent {
        struct AgentResponse: Decodable { let success: Bool; let data: CloudAgent }
        let response: AgentResponse = try await get("/api/agents/\(id)")
        return response.data
    }

    func createAgent(name: String, displayName: String, description: String? = nil, avatar: String? = nil, type: String, config: [String: Any]? = nil, permissions: [String: Any]? = nil, callbackUrl: String? = nil) async throws -> CloudAgent {
        struct CreateBody: Encodable {
            let name: String
            let displayName: String
            let description: String?
            let avatar: String?
            let type: String
            let config: [String: Any]?
            let permissions: [String: Any]?
            let callbackUrl: String?

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(name, forKey: .name)
                try container.encode(displayName, forKey: .displayName)
                try container.encodeIfPresent(description, forKey: .description)
                try container.encodeIfPresent(avatar, forKey: .avatar)
                try container.encode(type, forKey: .type)
                try container.encodeIfPresent(callbackUrl, forKey: .callbackUrl)

                // Encode config and permissions as nested JSON objects
                if let config = config {
                    var configContainer = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .config)
                    for (key, value) in config {
                        try encodeAny(value, forKey: AnyCodingKey(key), in: &configContainer)
                    }
                }
                if let permissions = permissions {
                    var permContainer = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .permissions)
                    for (key, value) in permissions {
                        try encodeAny(value, forKey: AnyCodingKey(key), in: &permContainer)
                    }
                }
            }

            private func encodeAny(_ value: Any, forKey key: AnyCodingKey, in container: inout KeyedEncodingContainer<AnyCodingKey>) throws {
                if let string = value as? String {
                    try container.encode(string, forKey: key)
                } else if let int = value as? Int {
                    try container.encode(int, forKey: key)
                } else if let double = value as? Double {
                    try container.encode(double, forKey: key)
                } else if let bool = value as? Bool {
                    try container.encode(bool, forKey: key)
                } else if let array = value as? [Any] {
                    var nested = container.nestedUnkeyedContainer(forKey: key)
                    for item in array {
                        try encodeAnyInArray(item, in: &nested)
                    }
                } else if let dict = value as? [String: Any] {
                    var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
                    for (k, v) in dict {
                        try encodeAny(v, forKey: AnyCodingKey(k), in: &nested)
                    }
                }
            }

            private func encodeAnyInArray(_ value: Any, in container: inout UnkeyedEncodingContainer) throws {
                if let string = value as? String {
                    try container.encode(string)
                } else if let int = value as? Int {
                    try container.encode(int)
                } else if let double = value as? Double {
                    try container.encode(double)
                } else if let bool = value as? Bool {
                    try container.encode(bool)
                }
            }

            enum CodingKeys: String, CodingKey {
                case name, displayName, description, avatar, type, config, permissions, callbackUrl
            }
        }

        let body = CreateBody(
            name: name,
            displayName: displayName,
            description: description,
            avatar: avatar,
            type: type,
            config: config,
            permissions: permissions,
            callbackUrl: callbackUrl
        )

        struct AgentResponse: Decodable { let success: Bool; let data: CloudAgent }
        let response: AgentResponse = try await post("/api/agents", body: body)
        return response.data
    }

    func updateAgent(id: String, displayName: String? = nil, description: String? = nil, avatar: String? = nil, config: [String: Any]? = nil, permissions: [String: Any]? = nil, callbackUrl: String? = nil, status: String? = nil) async throws -> CloudAgent {
        struct UpdateBody: Encodable {
            let displayName: String?
            let description: String?
            let avatar: String?
            let config: [String: Any]?
            let permissions: [String: Any]?
            let callbackUrl: String?
            let status: String?

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encodeIfPresent(displayName, forKey: .displayName)
                try container.encodeIfPresent(description, forKey: .description)
                try container.encodeIfPresent(avatar, forKey: .avatar)
                try container.encodeIfPresent(callbackUrl, forKey: .callbackUrl)
                try container.encodeIfPresent(status, forKey: .status)

                // Encode config and permissions as nested JSON objects
                if let config = config {
                    var configContainer = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .config)
                    for (key, value) in config {
                        try encodeAny(value, forKey: AnyCodingKey(key), in: &configContainer)
                    }
                }
                if let permissions = permissions {
                    var permContainer = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: .permissions)
                    for (key, value) in permissions {
                        try encodeAny(value, forKey: AnyCodingKey(key), in: &permContainer)
                    }
                }
            }

            private func encodeAny(_ value: Any, forKey key: AnyCodingKey, in container: inout KeyedEncodingContainer<AnyCodingKey>) throws {
                if let string = value as? String {
                    try container.encode(string, forKey: key)
                } else if let int = value as? Int {
                    try container.encode(int, forKey: key)
                } else if let double = value as? Double {
                    try container.encode(double, forKey: key)
                } else if let bool = value as? Bool {
                    try container.encode(bool, forKey: key)
                } else if let array = value as? [Any] {
                    var nested = container.nestedUnkeyedContainer(forKey: key)
                    for item in array {
                        try encodeAnyInArray(item, in: &nested)
                    }
                } else if let dict = value as? [String: Any] {
                    var nested = container.nestedContainer(keyedBy: AnyCodingKey.self, forKey: key)
                    for (k, v) in dict {
                        try encodeAny(v, forKey: AnyCodingKey(k), in: &nested)
                    }
                }
            }

            private func encodeAnyInArray(_ value: Any, in container: inout UnkeyedEncodingContainer) throws {
                if let string = value as? String {
                    try container.encode(string)
                } else if let int = value as? Int {
                    try container.encode(int)
                } else if let double = value as? Double {
                    try container.encode(double)
                } else if let bool = value as? Bool {
                    try container.encode(bool)
                }
            }

            enum CodingKeys: String, CodingKey {
                case displayName, description, avatar, config, permissions, callbackUrl, status
            }
        }

        let body = UpdateBody(
            displayName: displayName,
            description: description,
            avatar: avatar,
            config: config,
            permissions: permissions,
            callbackUrl: callbackUrl,
            status: status
        )

        struct AgentResponse: Decodable { let success: Bool; let data: CloudAgent }
        let response: AgentResponse = try await request("/api/agents/\(id)", method: "PATCH", body: body)
        return response.data
    }

    func deleteAgent(id: String) async throws {
        try await delete("/api/agents/\(id)")
    }

    // MARK: - Device API

    /// 注册或更新设备（upsert by deviceId）
    func registerDevice(
        deviceId: String,
        deviceName: String,
        kind: String,
        runtimeType: String? = nil,
        runtimeServer: String? = nil,
        machineId: String? = nil,
        osVersion: String? = nil,
        appVersion: String? = nil
    ) async throws -> CoreDevice {
        struct Body: Encodable {
            let deviceId: String
            let deviceName: String
            let kind: String
            let runtimeType: String?
            let runtimeServer: String?
            let machineId: String?
            let osVersion: String?
            let appVersion: String?
        }
        struct DeviceResponse: Decodable { let success: Bool; let device: CoreDevice }
        let body = Body(deviceId: deviceId, deviceName: deviceName, kind: kind, runtimeType: runtimeType, runtimeServer: runtimeServer, machineId: machineId, osVersion: osVersion, appVersion: appVersion)
        let response: DeviceResponse = try await post("/api/devices", body: body)
        return response.device
    }

    /// 列出设备（可选按 kind 过滤）
    func listDevices(kind: String? = nil) async throws -> [CoreDevice] {
        let path = kind.map { "/api/devices?kind=\($0)" } ?? "/api/devices"
        struct DevicesResponse: Decodable { let success: Bool; let devices: [CoreDevice] }
        let response: DevicesResponse = try await get(path)
        return response.devices
    }

    /// 绑定设备到 Agent
    func bindAgentDevice(agentId: String, deviceId: String, bindType: String, bindSource: String = "qr") async throws -> CoreDeviceBinding {
        struct Body: Encodable { let deviceId: String; let bindType: String; let bindSource: String }
        struct BindingResponse: Decodable { let success: Bool; let binding: CoreDeviceBinding }
        let response: BindingResponse = try await post("/api/agents/\(agentId)/bindings", body: Body(deviceId: deviceId, bindType: bindType, bindSource: bindSource))
        return response.binding
    }

    /// 列出 Agent 的所有绑定
    func listAgentBindings(agentId: String) async throws -> [CoreDeviceBinding] {
        struct BindingsResponse: Decodable { let success: Bool; let bindings: [CoreDeviceBinding] }
        let response: BindingsResponse = try await get("/api/agents/\(agentId)/bindings")
        return response.bindings
    }

    func sessionSyncBootstrap(deviceId: String, sessions: [CoreSessionBootstrapItem]) async throws -> CoreSessionSyncPushResponse {
        struct Body: Encodable {
            let deviceId: String
            let sessions: [CoreSessionBootstrapItem]
        }
        return try await post("/api/sessions/bootstrap", body: Body(deviceId: deviceId, sessions: sessions))
    }

    func sessionSyncPush(deviceId: String, ops: [CoreSessionSyncOperation]) async throws -> CoreSessionSyncPushResponse {
        struct Body: Encodable {
            let deviceId: String
            let ops: [CoreSessionSyncOperation]
        }
        return try await post("/api/sessions/sync/push", body: Body(deviceId: deviceId, ops: ops))
    }

    func sessionSyncPull(cursor: Int, limit: Int = 200) async throws -> CoreSessionSyncPullResponse {
        let path = makePath(
            "/api/sessions/sync/pull",
            queryItems: [
                URLQueryItem(name: "cursor", value: String(cursor)),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
        return try await get(path)
    }

    func appendEvent(event: CgoEventInput) async throws -> CgoEvent {
        struct EventResponse: Decodable {
            let success: Bool
            let data: CgoEvent
        }
        let response: EventResponse = try await post("/api/events", body: event)
        return response.data
    }

    func listSyncedSessions(offset: Int = 0, limit: Int = 200) async throws -> [CoreSessionHead] {
        let path = makePath(
            "/api/sessions",
            queryItems: [
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "limit", value: String(limit)),
            ]
        )
        struct SessionsResponse: Decodable {
            let success: Bool
            let data: [CoreSessionHead]
        }
        let response: SessionsResponse = try await get(path)
        return response.data
    }

    func getSyncedSession(sessionId: String, messageLimit: Int = 200) async throws -> CoreSessionSnapshot {
        let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sessionId
        let path = makePath(
            "/api/sessions/\(encoded)",
            queryItems: [URLQueryItem(name: "messageLimit", value: String(messageLimit))]
        )
        struct SessionResponse: Decodable {
            let success: Bool
            let data: CoreSessionSnapshot
        }
        let response: SessionResponse = try await get(path)
        return response.data
    }

    func getSyncedSessionByURI(sessionURI: String, messageLimit: Int = 200) async throws -> CoreSessionSnapshot {
        let path = makePath(
            "/api/sessions/resolve/by-uri",
            queryItems: [
                URLQueryItem(name: "uri", value: sessionURI),
                URLQueryItem(name: "messageLimit", value: String(messageLimit)),
            ]
        )
        struct SessionResponse: Decodable {
            let success: Bool
            let data: CoreSessionSnapshot
        }
        let response: SessionResponse = try await get(path)
        return response.data
    }

    private func makePath(_ path: String, queryItems: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.path = path
        components.queryItems = queryItems
        return components.string ?? path
    }

    private func buildSpaceUri(spaceId: String) -> String {
        return "ctxgo://\(spaceId)/space/root"
    }

    func makeSpaceUri(spaceId: String) -> String {
        return buildSpaceUri(spaceId: spaceId)
    }

    private func buildContextUri(spaceId: String) -> String {
        return "ctxgo://\(spaceId)/context/space"
    }

    func makeContextUri(spaceId: String) -> String {
        return buildContextUri(spaceId: spaceId)
    }
}

// MARK: - Private Helpers

private struct EmptyResponse: Decodable {}
private struct EmptyBody: Encodable {}

struct CoreContextSearchResult: Decodable, Identifiable {
    let id: String
    let spaceId: String
    let date: String
    let intent: String
    let result: String
    let score: Int
    let kind: String?
    let status: String?
    let importanceScore: Int?
    let importanceReason: String?
    let entryUri: String?
    let sourceEventId: String?
}

struct CoreContextRelations: Codable {
    let tasks: [String]?
    let attachments: [String]?
    let skills: [String]?
    let contexts: [String]?
}

struct CoreContextEntryMeta: Codable {
    let contextKind: String?
    let status: String?
    let importanceScore: Int?
    let importanceReason: String?
    let sourceEventId: String?
}

// MARK: - Device Models

struct CoreDevice: Identifiable, Decodable {
    let deviceId: String
    let deviceName: String
    let kind: String            // "runtime" | "controller"
    let runtimeType: String?    // e.g. "contextgo-cli"
    let runtimeServer: String?
    let machineId: String?
    let osVersion: String?
    let appVersion: String?
    let lastSeenAt: String
    let createdAt: String
    let updatedAt: String

    var id: String { deviceId }
}

struct CoreDeviceBinding: Identifiable, Decodable {
    let id: String
    let agentId: String
    let deviceId: String
    let bindType: String        // "runtime" | "controller"
    let status: String          // "active" | "inactive"
    let bindSource: String
    let createdAt: String
    let updatedAt: String
}

struct CoreSessionHead: Codable, Identifiable {
    let id: String
    let sessionUri: String?
    let agentId: String
    let title: String
    let preview: String
    let tags: [String]
    let createdAt: String
    let updatedAt: String
    let lastMessageTime: String
    let isActive: Bool
    let isPinned: Bool
    let isArchived: Bool
    let syncStatus: String?
    let lastSyncAt: String?
    let channelMetadataRaw: String?
}

struct CoreSessionMessage: Codable {
    let id: String
    let sessionId: String
    let timestamp: String
    let role: String
    let content: String
    let toolCalls: [AnyCodable]?
    let toolResults: [AnyCodable]?
    let metadata: [String: AnyCodable]?
}

struct CoreSessionSnapshot: Codable {
    let session: CoreSessionHead
    let messages: [CoreSessionMessage]
}

struct CoreSessionBootstrapItem: Codable {
    let session: CoreSessionHead
    let messages: [CoreSessionMessage]?
}

struct CoreSessionSyncOperation: Codable {
    let opId: String
    let type: String
    let sessionId: String
    let clientTimestamp: String
    let session: CoreSessionHead?
    let patch: CoreSessionHeadPatch?
    let message: CoreSessionMessage?
}

struct CoreSessionHeadPatch: Codable {
    let title: String?
    let preview: String?
    let tags: [String]?
    let updatedAt: String?
    let lastMessageTime: String?
    let isActive: Bool?
    let isPinned: Bool?
    let isArchived: Bool?
    let syncStatus: String?
    let lastSyncAt: String?
    let channelMetadataRaw: String?
}

struct CoreSessionSyncPushResponse: Decodable {
    let success: Bool
    let appliedOpIds: [String]
    let duplicateOpIds: [String]
    let rejected: [CoreSessionSyncRejectedOp]
    let cursor: Int
}

struct CoreSessionSyncRejectedOp: Decodable {
    let opId: String
    let error: String
}

struct CoreSessionSyncEvent: Decodable {
    let sequence: Int
    let opId: String
    let type: String
    let sessionId: String
    let clientTimestamp: String
    let serverTimestamp: String
    let deviceId: String
    let session: CoreSessionHead?
    let patch: CoreSessionHeadPatch?
    let message: CoreSessionMessage?
}

struct CoreSessionSyncPullResponse: Decodable {
    let success: Bool
    let events: [CoreSessionSyncEvent]
    let nextCursor: Int
}

enum CoreSessionEventProvider: String, Codable {
    case openclaw
    case claudecode
    case codex
    case geminicli
    case opencode
    case contextgoCore = "contextgo-core"
    case contextgoCLI = "contextgo-cli"
    case contextgoIOS = "contextgo-ios"

    static func fromRuntimeValue(_ raw: String?) -> CoreSessionEventProvider {
        let normalized = raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "") ?? ""

        switch normalized {
        case "openclaw":
            return .openclaw
        case "claude", "claudecode":
            return .claudecode
        case "codex":
            return .codex
        case "gemini", "geminicli":
            return .geminicli
        case "opencode":
            return .opencode
        case "contextgocore":
            return .contextgoCore
        case "contextgoios":
            return .contextgoIOS
        default:
            return .contextgoCLI
        }
    }
}

enum CoreSessionEventSource: String, Codable {
    case coreInternal = "core.internal"
    case coreContext = "core.context"
    case coreApiSessions = "core.api.sessions"
    case coreApiEvents = "core.api.events"
    case cliRuntime = "cli.runtime"
    case iosCLI = "ios.cli"
    case iosAttachmentUpload = "ios.attachment.upload"
    case iosContextBuildMeetingRecording = "ios.context-build.meeting-recording"
}

enum CgoEventType: String, Codable {
    case sessionClaimed = "session.claimed"
    case sessionStarted = "session.started"
    case sessionPaused = "session.paused"
    case sessionResumed = "session.resumed"
    case sessionEnded = "session.ended"
    case sessionStateChanged = "session.state_changed"
    case sessionFinalized = "session.finalized"
    case messageAppended = "message.appended"
    case messageCleared = "message.cleared"
    case contextSelected = "context.selected"
    case contextCreated = "context.created"
    case contextStatusChanged = "context.status_changed"
    case contextReviewRequested = "context.review.requested"
    case contextReviewCompleted = "context.review.completed"
    case contextReviewFailed = "context.review.failed"
    case turnStarted = "turn.started"
    case turnStreamed = "turn.streamed"
    case turnCompleted = "turn.completed"
    case turnAborted = "turn.aborted"
    case toolCalled = "tool.called"
    case toolResulted = "tool.resulted"
    case toolFailed = "tool.failed"
    case taskClaimed = "task.claimed"
    case taskProgressed = "task.progressed"
    case taskCompleted = "task.completed"
    case taskFailed = "task.failed"
    case taskCancelled = "task.cancelled"
    case memorySnapshot = "memory.snapshot"
    case memoryCondensed = "memory.condensed"
    case memoryPersisted = "memory.persisted"
    case hookCalled = "hook.called"
    case hookFailed = "hook.failed"
    case hookTimedOut = "hook.timed_out"
    case skillLoaded = "skill.loaded"
    case skillApplied = "skill.applied"
    case skillCandidateCollected = "skill.candidate_collected"
    case skillUsageRecorded = "skill.usage_recorded"
    case skillEvolveStarted = "skill.evolve_started"
    case skillEvolved = "skill.evolved"
    case skillEvolveFailed = "skill.evolve_failed"
    case attachmentUploaded = "attachment.uploaded"
    case meetingNotesUploaded = "meeting.notes_uploaded"
}

enum CgoEventScopeType: String, Codable {
    case session
    case space
    case system
}

struct CgoEventScopeInput: Codable {
    let type: CgoEventScopeType
    let sessionId: String?
    let sessionKey: String?
    let attemptId: String?
    let spaceId: String?
    let key: String?

    static func session(sessionId: String, sessionKey: String, attemptId: String) -> CgoEventScopeInput {
        CgoEventScopeInput(
            type: .session,
            sessionId: sessionId,
            sessionKey: sessionKey,
            attemptId: attemptId,
            spaceId: nil,
            key: nil
        )
    }

    static func space(spaceId: String) -> CgoEventScopeInput {
        CgoEventScopeInput(
            type: .space,
            sessionId: nil,
            sessionKey: nil,
            attemptId: nil,
            spaceId: spaceId,
            key: nil
        )
    }

    static func system(key: String? = nil) -> CgoEventScopeInput {
        CgoEventScopeInput(
            type: .system,
            sessionId: nil,
            sessionKey: nil,
            attemptId: nil,
            spaceId: nil,
            key: key
        )
    }
}

struct CgoEventInput: Codable {
    let eventId: String?
    let scope: CgoEventScopeInput
    let provider: CoreSessionEventProvider
    let source: CoreSessionEventSource
    let type: CgoEventType
    let timestamp: String?
    let payload: [String: AnyCodable]
}

struct CgoEventScope: Decodable {
    let type: CgoEventScopeType
    let sessionId: String?
    let sessionKey: String?
    let attemptId: String?
    let spaceId: String?
    let key: String?
}

struct CgoEvent: Decodable {
    let eventId: String
    let scope: CgoEventScope
    let provider: String
    let source: String
    let type: String
    let timestamp: String
    let payload: [String: AnyCodable]
    let seq: Int?
}

struct CoreAttachmentInfo: Codable, Identifiable {
    let id: String
    let hash: String
    let md5: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
    let storageUri: String
    let attachmentUri: String
    let createdAt: String
    let userId: String?
}

struct CoreAttachmentURLData: Codable {
    let url: String
    let etag: String?
    let sha256: String
    let md5: String
}

struct CoreAttachmentDownloadData: Codable {
    let attachmentUri: String
    let fileName: String
    let mimeType: String
    let sizeBytes: Int
    let sha256: String
    let md5: String
    let etag: String?
    let notModified: Bool
    let contentBase64: String?
}
