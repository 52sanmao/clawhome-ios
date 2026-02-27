//
//  ContextGoSession.swift
//  contextgo
//
//  统一 Session 模型 - 所有渠道的会话抽象
//

import Foundation
import GRDB

/// Context Go 统一 Session 模型
/// 设计原则：
/// 1. 唯一 ID: provider-native（例如 session_xxx）
/// 2. 关联 Agent（通过 agentId）
/// 3. 渠道元数据存在 JSON 字段（灵活扩展）
/// 4. 本地消息缓存在 JSONL 文件
struct ContextGoSession: Codable, FetchableRecord, PersistableRecord, Identifiable {
    // MARK: - Core Identity
    var id: String              // provider-native session id (e.g. session_xxx)
    var agentId: String         // 关联的 Agent ID

    // MARK: - Display Info
    var title: String           // Session 标题
    var preview: String         // 消息预览
    var tags: [String]          // 标签（用于分类、搜索）

    // MARK: - Timestamps
    var createdAt: Date         // 创建时间
    var updatedAt: Date         // 最后更新时间（元数据变更）
    var lastMessageTime: Date   // 最后消息时间（用于排序）

    // MARK: - State
    var isActive: Bool          // 是否活跃（正在运行）
    var isPinned: Bool          // 是否置顶
    var isArchived: Bool        // 是否归档

    // MARK: - Channel-Specific Metadata (JSON 存储)
    /// 渠道原始元数据（JSON 字符串）
    /// 不同渠道存不同的数据：
    /// - OpenClaw: { "sessionKey": "agent:main:operator:xxx" }
    /// - CLI Relay: { "cliSessionId": "abc", "machineId": "xyz", "path": "~/project", "flavor": "claude" }
    var channelMetadata: String?

    // MARK: - Local Cache
    /// 消息缓存文件路径（相对路径）
    /// 例如: "users/local/sessions/{agentId}/{sessionId}/messages.jsonl"
    var messagesCachePath: String

    // MARK: - Sync State (未来多端同步)
    var syncStatus: SyncStatus  // 同步状态
    var lastSyncAt: Date?       // 最后同步时间

    // MARK: - Database Table
    static let databaseTableName = "contextgo_sessions"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let agentId = Column(CodingKeys.agentId)
        static let title = Column(CodingKeys.title)
        static let preview = Column(CodingKeys.preview)
        static let tags = Column(CodingKeys.tags)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let lastMessageTime = Column(CodingKeys.lastMessageTime)
        static let isActive = Column(CodingKeys.isActive)
        static let isPinned = Column(CodingKeys.isPinned)
        static let isArchived = Column(CodingKeys.isArchived)
        static let channelMetadata = Column(CodingKeys.channelMetadata)
        static let messagesCachePath = Column(CodingKeys.messagesCachePath)
        static let syncStatus = Column(CodingKeys.syncStatus)
        static let lastSyncAt = Column(CodingKeys.lastSyncAt)
    }
}

// MARK: - Sync Status

enum SyncStatus: String, Codable, DatabaseValueConvertible {
    case synced     // 已同步
    case pending    // 待上传
    case conflict   // 冲突（多端修改）
    case localOnly  // 仅本地（不同步）
}

// MARK: - Helper Computed Properties

extension ContextGoSession {
    /// 解析渠道元数据为字典（便于访问）
    var channelMetadataDict: [String: Any]? {
        guard let json = channelMetadata,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    /// 设置渠道元数据（从字典）
    mutating func setChannelMetadata(_ dict: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: dict),
           let json = String(data: data, encoding: .utf8) {
            self.channelMetadata = json
        }
    }

    mutating func markRemoteDeleted(provider: String, at date: Date = Date()) {
        isActive = false
        isArchived = true
        syncStatus = .conflict
        updatedAt = date
        lastSyncAt = date

        var metadata = channelMetadataDict ?? [:]
        metadata["remoteDeleted"] = true
        metadata["remoteDeletedProvider"] = provider
        metadata["remoteDeletedAt"] = Int64(date.timeIntervalSince1970 * 1000)
        setChannelMetadata(metadata)
    }

    /// 获取消息缓存的绝对路径
    func messagesCacheURL(baseURL: URL) -> URL {
        return baseURL.appendingPathComponent(messagesCachePath)
    }

    /// 检查是否为 CLI Relay Session
    var isCLISession: Bool {
        return id.hasPrefix("ctxgo://cli-") ||
               (channelMetadataDict?["cliSessionId"] != nil)
    }

    var cliSessionId: String? {
        guard isCLISession else { return nil }

        if id.hasPrefix("ctxgo://cli-") {
            return String(id.dropFirst("ctxgo://cli-".count))
        }

        // 从元数据中提取（兜底）
        return channelMetadataDict?["cliSessionId"] as? String
    }
}

// MARK: - Factory Methods

extension ContextGoSession {
    /// 从 OpenClaw Agent 创建新 Session（带时间戳，支持多 Session）
    /// sessionKey 格式: agent:main:operator:{agentId}:{YYYYMMddHHmmss}
    static func fromOpenClawNew(agent: CloudAgent, title: String? = nil) -> ContextGoSession {
        // Generate random suffix (21 chars, URL-safe base64-like)
        let randomBytes = (0..<16).map { _ in UInt8.random(in: 0...255) }
        let randomData = Data(randomBytes)
        let randomSuffix = randomData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .prefix(21)

        let sessionId = "session_\(String(randomSuffix))"
        let sessionKey = "agent:main:operator:\(randomSuffix)"

        let metadata: [String: Any] = [
            "sessionKey": sessionKey,
            "remoteSessionId": sessionId
        ]

        var session = ContextGoSession(
            id: sessionId,
            agentId: agent.id,
            title: title ?? "New Chat",
            preview: "",
            tags: ["openclaw"],
            createdAt: Date(),
            updatedAt: Date(),
            lastMessageTime: Date(),
            isActive: false,
            isPinned: false,
            isArchived: false,
            channelMetadata: nil,
            messagesCachePath: SessionStorageLayout.messagesRelativePath(agentId: agent.id, sessionId: sessionId),
            syncStatus: .localOnly,
            lastSyncAt: nil
        )

        session.setChannelMetadata(metadata)
        return session
    }

    static func fromOpenClaw(agent: CloudAgent) -> ContextGoSession {
        let sessionId = "session_\(agent.id)"
        let sessionKey = "agent:main:operator:\(agent.id)"

        let metadata: [String: Any] = [
            "sessionKey": sessionKey,
            "remoteSessionId": sessionId
        ]

        var session = ContextGoSession(
            id: sessionId,
            agentId: agent.id,
            title: agent.uiDisplayName,
            preview: "",
            tags: ["openclaw"],
            createdAt: Date(),
            updatedAt: Date(),
            lastMessageTime: Date(),
            isActive: false,
            isPinned: false,
            isArchived: false,
            channelMetadata: nil,
            messagesCachePath: SessionStorageLayout.messagesRelativePath(agentId: agent.id, sessionId: sessionId),
            syncStatus: .localOnly,
            lastSyncAt: nil
        )

        session.setChannelMetadata(metadata)
        return session
    }

    /// 从 CLI Relay Session 创建 ContextGoSession
    static func fromCLI(
        cliSessionId: String,
        agent: CloudAgent,
        title: String,
        preview: String,
        lastMessageTime: Date,
        isActive: Bool,
        metadata: SessionMetadata?
    ) -> ContextGoSession {
        let sessionId = cliSessionId

        var channelMetadata: [String: Any] = [
            "cliSessionId": cliSessionId,
            "sessionUri": SessionStorageLayout.sessionResourceURI(agentId: agent.id, sessionId: cliSessionId)
        ]

        // 从 SessionMetadata 提取字段
        if let meta = metadata {
            if let path = meta.path {
                channelMetadata["path"] = path
            }
            if let pathBasename = meta.pathBasename {
                channelMetadata["pathBasename"] = pathBasename
            }
            if let machineId = meta.machineId {
                channelMetadata["machineId"] = machineId
            }
            if let host = meta.host {
                channelMetadata["host"] = host
            }
            if let hostPid = meta.hostPid {
                channelMetadata["hostPid"] = hostPid
            }
            if let customTitle = meta.customTitle {
                channelMetadata["customTitle"] = customTitle
            }
            if let flavor = meta.aiProvider {
                channelMetadata["flavor"] = flavor
            }
            if let homeDir = meta.homeDir {
                channelMetadata["homeDir"] = homeDir
            }
            if let claudeSessionId = meta.claudeSessionId {
                channelMetadata["claudeSessionId"] = claudeSessionId
            }
            if let codexSessionId = meta.codexSessionId {
                channelMetadata["codexSessionId"] = codexSessionId
            }
            if let opencodeSessionId = meta.opencodeSessionId {
                channelMetadata["opencodeSessionId"] = opencodeSessionId
            }
            if let geminiSessionId = meta.geminiSessionId {
                channelMetadata["geminiSessionId"] = geminiSessionId
            }
        }

        var tags = ["cli"]
        if agent.channelType == .claudeCode {
            tags.append("claude-code")
        } else if agent.channelType == .codex {
            tags.append("codex")
        }

        var session = ContextGoSession(
            id: sessionId,
            agentId: agent.id,
            title: title,
            preview: preview,
            tags: tags,
            createdAt: Date(),  // 注意：创建时间应该从 relay server 获取
            updatedAt: Date(),
            lastMessageTime: lastMessageTime,
            isActive: isActive,
            isPinned: false,
            isArchived: false,
            channelMetadata: nil,
            messagesCachePath: SessionStorageLayout.messagesRelativePath(agentId: agent.id, sessionId: sessionId),
            syncStatus: .synced,  // relay server 已同步
            lastSyncAt: Date()
        )

        session.setChannelMetadata(channelMetadata)
        return session
    }
}

// MARK: - Tags Array Encoding (GRDB)

extension ContextGoSession {
    // GRDB 需要手动处理数组字段的编码/解码
    private enum TagsKey: String {
        case tags
    }

    mutating func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.agentId] = agentId
        container[Columns.title] = title
        container[Columns.preview] = preview
        container[Columns.createdAt] = createdAt
        container[Columns.updatedAt] = updatedAt
        container[Columns.lastMessageTime] = lastMessageTime
        container[Columns.isActive] = isActive
        container[Columns.isPinned] = isPinned
        container[Columns.isArchived] = isArchived
        container[Columns.channelMetadata] = channelMetadata
        container[Columns.messagesCachePath] = messagesCachePath
        container[Columns.syncStatus] = syncStatus
        container[Columns.lastSyncAt] = lastSyncAt

        // Tags: 存为 JSON 数组字符串
        if let data = try? JSONEncoder().encode(tags),
           let json = String(data: data, encoding: .utf8) {
            container[Columns.tags] = json
        } else {
            container[Columns.tags] = "[]"
        }
    }

    init(row: Row) {
        id = row[Columns.id]
        agentId = row[Columns.agentId]
        title = row[Columns.title]
        preview = row[Columns.preview]
        createdAt = row[Columns.createdAt]
        updatedAt = row[Columns.updatedAt]
        lastMessageTime = row[Columns.lastMessageTime]
        isActive = row[Columns.isActive]
        isPinned = row[Columns.isPinned]
        isArchived = row[Columns.isArchived]
        channelMetadata = row[Columns.channelMetadata]
        messagesCachePath = row[Columns.messagesCachePath]
        syncStatus = row[Columns.syncStatus]
        lastSyncAt = row[Columns.lastSyncAt]

        // Tags: 从 JSON 数组字符串解析
        if let tagsJSON: String = row[Columns.tags],
           let data = tagsJSON.data(using: .utf8),
           let decodedTags = try? JSONDecoder().decode([String].self, from: data) {
            tags = decodedTags
        } else {
            tags = []
        }
    }
}
