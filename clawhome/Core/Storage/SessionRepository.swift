//
//  SessionRepository.swift
//  contextgo
//
//  统一 Session 存储接口
//

import Foundation
import GRDB

/// Session 存储接口（元数据 + 消息缓存）
protocol SessionRepository {
    // MARK: - Session CRUD（元数据）
    func createSession(_ session: ContextGoSession, notifyCloud: Bool) async throws
    func getSession(id: String) async throws -> ContextGoSession?
    func getAllSessions(agentId: String?) async throws -> [ContextGoSession]
    func updateSession(_ session: ContextGoSession, notifyCloud: Bool) async throws
    func deleteSession(id: String, notifyCloud: Bool) async throws

    // MARK: - Query
    func getActiveSessions(agentId: String?) async throws -> [ContextGoSession]
    func getPinnedSessions() async throws -> [ContextGoSession]

    // MARK: - Message Cache（本地缓存，可清理）
    func cacheMessage(_ message: SessionMessage, to sessionId: String, notifyCloud: Bool) async throws
    func getCachedMessages(sessionId: String, limit: Int?, offset: Int?) async throws -> [SessionMessage]
    func getSessionByResourceURI(_ sessionResourceURI: String) async throws -> ContextGoSession?
    func getCachedMessagesByResourceURI(_ sessionResourceURI: String, limit: Int?, offset: Int?) async throws -> [SessionMessage]
    func clearMessageCache(sessionId: String, notifyCloud: Bool) async throws
}

extension SessionRepository {
    func createSession(_ session: ContextGoSession) async throws {
        try await createSession(session, notifyCloud: true)
    }

    func updateSession(_ session: ContextGoSession) async throws {
        try await updateSession(session, notifyCloud: true)
    }

    func deleteSession(id: String) async throws {
        try await deleteSession(id: id, notifyCloud: true)
    }

    func cacheMessage(_ message: SessionMessage, to sessionId: String) async throws {
        try await cacheMessage(message, to: sessionId, notifyCloud: true)
    }

    func clearMessageCache(sessionId: String) async throws {
        try await clearMessageCache(sessionId: sessionId, notifyCloud: true)
    }

    func getSessionByResourceURI(_ sessionResourceURI: String) async throws -> ContextGoSession? {
        guard let parsed = SessionStorageLayout.parseSessionResourceURI(sessionResourceURI) else {
            return nil
        }
        guard let session = try await getSession(id: parsed.sessionId) else { return nil }
        return session.agentId == parsed.agentId ? session : nil
    }

    func getCachedMessagesByResourceURI(_ sessionResourceURI: String, limit: Int?, offset: Int?) async throws -> [SessionMessage] {
        guard let session = try await getSessionByResourceURI(sessionResourceURI) else { return [] }
        return try await getCachedMessages(sessionId: session.id, limit: limit, offset: offset)
    }
}

/// 本地 Session 存储实现（GRDB + JSONL）
@MainActor
class LocalSessionRepository: SessionRepository {
    // MARK: - Singleton
    static let shared = LocalSessionRepository()

    // MARK: - Properties
    private var dbQueue: DatabaseQueue?
    private let fileManager = FileManager.default
    private let sessionsDirectory: URL
    private var isInitialized = false
    private let metadataEncoder = JSONEncoder()
    private let metadataDecoder = JSONDecoder()
    private let initRetryDelayNs: UInt64 = 50_000_000
    private let initMaxWaitNs: UInt64 = 5_000_000_000
    private let messageReadQueue = DispatchQueue(label: "contextgo.sessions.message-read", qos: .userInitiated)

    // MARK: - Initialization

    init(baseDirectory: URL? = nil) {
        let storageRoot: URL
        if let baseDirectory {
            storageRoot = baseDirectory
        } else {
            storageRoot = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        sessionsDirectory = storageRoot.appendingPathComponent("sessions")

        // 创建 sessions 目录
        if !fileManager.fileExists(atPath: sessionsDirectory.path) {
            try? fileManager.createDirectory(at: sessionsDirectory, withIntermediateDirectories: true)
        }
        migrateLegacySessionLayoutIfNeeded()

        metadataEncoder.dateEncodingStrategy = .iso8601
        metadataDecoder.dateDecodingStrategy = .iso8601

        Task {
            await initializeDatabase()
        }
    }

    private func initializeDatabase() async {
        guard !isInitialized else { return }

        let dbPath = sessionsDirectory.appendingPathComponent("metadata.db").path

        do {
            dbQueue = try DatabaseQueue(path: dbPath)
            try await dbQueue?.write { db in
                try db.create(table: ContextGoSession.databaseTableName, ifNotExists: true) { t in
                    t.column("id", .text).primaryKey()
                    t.column("agentId", .text).notNull().indexed()
                    t.column("title", .text).notNull()
                    t.column("preview", .text).notNull()
                    t.column("tags", .text).notNull()  // JSON 数组字符串
                    t.column("createdAt", .datetime).notNull()
                    t.column("updatedAt", .datetime).notNull().indexed()
                    t.column("lastMessageTime", .datetime).notNull().indexed()
                    t.column("isActive", .boolean).notNull().indexed()
                    t.column("isPinned", .boolean).notNull().indexed()
                    t.column("isArchived", .boolean).notNull().indexed()
                    t.column("channelMetadata", .text)  // JSON 字符串
                    t.column("messagesCachePath", .text).notNull()
                    t.column("syncStatus", .text).notNull()
                    t.column("lastSyncAt", .datetime)
                }
            }
            isInitialized = true
            print("✅ SessionRepository initialized: \(dbPath)")
        } catch {
            print("❌ Failed to initialize SessionRepository: \(error)")
        }
    }

    func ensureInitialized() async throws {
        if isInitialized { return }

        let start = DispatchTime.now().uptimeNanoseconds
        while !isInitialized {
            let elapsed = DispatchTime.now().uptimeNanoseconds - start
            if elapsed >= initMaxWaitNs {
                throw SessionRepositoryError.databaseNotInitialized
            }
            try await Task.sleep(nanoseconds: initRetryDelayNs)
        }
    }

    // MARK: - Session CRUD

    func createSession(_ session: ContextGoSession, notifyCloud: Bool = true) async throws {
        _ = notifyCloud // 保留接口参数，当前阶段仅本地落盘
        guard let db = dbQueue else {
            throw SessionRepositoryError.databaseNotInitialized
        }

        let normalizedSession: ContextGoSession = {
            var value = session
            value.messagesCachePath = SessionStorageLayout.messagesRelativePath(
                agentId: session.agentId,
                sessionId: session.id
            )
            return value
        }()

        try await db.write { db in
            try normalizedSession.insert(db)
        }

        try upsertStorageMetadata(for: normalizedSession)

        print("💾 [CREATE] Session: \(normalizedSession.id) - \(normalizedSession.title)")

    }

    func getSession(id: String) async throws -> ContextGoSession? {
        guard let db = dbQueue else {
            throw SessionRepositoryError.databaseNotInitialized
        }

        return try await db.read { db in
            try ContextGoSession.fetchOne(db, key: id)
        }
    }

    func getAllSessions(agentId: String?) async throws -> [ContextGoSession] {
        guard let db = dbQueue else {
            throw SessionRepositoryError.databaseNotInitialized
        }

        return try await db.read { db in
            var request = ContextGoSession
                .filter(ContextGoSession.Columns.isArchived == false)
                .order(ContextGoSession.Columns.isPinned.desc, ContextGoSession.Columns.lastMessageTime.desc)

            if let agentId = agentId {
                request = request.filter(ContextGoSession.Columns.agentId == agentId)
            }

            return try request.fetchAll(db)
        }
    }

    func getAllSessionsIncludingArchived(agentId: String?) async throws -> [ContextGoSession] {
        guard let db = dbQueue else {
            throw SessionRepositoryError.databaseNotInitialized
        }

        return try await db.read { db in
            var request = ContextGoSession
                .order(ContextGoSession.Columns.isPinned.desc, ContextGoSession.Columns.lastMessageTime.desc)

            if let agentId = agentId {
                request = request.filter(ContextGoSession.Columns.agentId == agentId)
            }

            return try request.fetchAll(db)
        }
    }

    func updateSession(_ session: ContextGoSession, notifyCloud: Bool = true) async throws {
        _ = notifyCloud // 保留接口参数，当前阶段仅本地落盘
        guard let db = dbQueue else {
            throw SessionRepositoryError.databaseNotInitialized
        }

        let normalizedSession: ContextGoSession = {
            var value = session
            value.messagesCachePath = SessionStorageLayout.messagesRelativePath(
                agentId: session.agentId,
                sessionId: session.id
            )
            return value
        }()

        try await db.write { db in
            try normalizedSession.update(db)
        }

        try upsertStorageMetadata(for: normalizedSession)

        print("💾 [UPDATE] Session: \(normalizedSession.id) - \(normalizedSession.title)")

    }

    func deleteSession(id: String, notifyCloud: Bool = true) async throws {
        _ = notifyCloud // 保留接口参数，当前阶段仅本地落盘
        guard let db = dbQueue else {
            throw SessionRepositoryError.databaseNotInitialized
        }

        let sessionToDelete = try await getSession(id: id)

        try await db.write { db in
            _ = try ContextGoSession.deleteOne(db, key: id)
        }

        if let sessionToDelete {
            try removeSessionDirectory(for: sessionToDelete)
        }

        print("💾 [DELETE] Session: \(id)")

    }

    // MARK: - Query

    func getActiveSessions(agentId: String?) async throws -> [ContextGoSession] {
        guard let db = dbQueue else {
            throw SessionRepositoryError.databaseNotInitialized
        }

        return try await db.read { db in
            var request = ContextGoSession
                .filter(ContextGoSession.Columns.isActive == true)
                .order(ContextGoSession.Columns.lastMessageTime.desc)

            if let agentId = agentId {
                request = request.filter(ContextGoSession.Columns.agentId == agentId)
            }

            return try request.fetchAll(db)
        }
    }

    func getPinnedSessions() async throws -> [ContextGoSession] {
        guard let db = dbQueue else {
            throw SessionRepositoryError.databaseNotInitialized
        }

        return try await db.read { db in
            try ContextGoSession
                .filter(ContextGoSession.Columns.isPinned == true)
                .order(ContextGoSession.Columns.lastMessageTime.desc)
                .fetchAll(db)
        }
    }

    // MARK: - Message Cache

    func cacheMessage(_ message: SessionMessage, to sessionId: String, notifyCloud: Bool = true) async throws {
        _ = notifyCloud // 保留接口参数，当前阶段仅本地落盘
        guard let session = try await getSession(id: sessionId) else {
            throw SessionRepositoryError.sessionNotFound
        }

        let jsonlPath = messagesPath(for: session)
        var existingMessages: [SessionMessage] = []

        if fileManager.fileExists(atPath: jsonlPath.path) {
            existingMessages = try parseMessages(at: jsonlPath)

            if let messageIndex = existingMessages.firstIndex(where: { $0.id == message.id }) {
                existingMessages[messageIndex] = message
                try rewriteMessages(existingMessages, to: jsonlPath)
                try upsertStorageMetadata(for: session)
                return
            }

            if let incomingRawMessageId = stableRawMessageId(from: message),
               let messageIndex = existingMessages.firstIndex(where: { stableRawMessageId(from: $0) == incomingRawMessageId }) {
                existingMessages[messageIndex] = message
                try rewriteMessages(existingMessages, to: jsonlPath)
                try upsertStorageMetadata(for: session)
                return
            }

            if existingMessages.contains(where: { isLikelyDuplicateMessage($0, message) }) {
                return
            }
        }

        // 确保目录存在
        let directory = jsonlPath.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        // 编码消息
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(message)
        guard let line = String(data: data, encoding: .utf8) else {
            throw SessionRepositoryError.encodingFailed
        }

        // 追加到 JSONL 文件
        if fileManager.fileExists(atPath: jsonlPath.path) {
            let fileHandle = try FileHandle(forWritingTo: jsonlPath)
            defer { try? fileHandle.close() }
            fileHandle.seekToEndOfFile()
            fileHandle.write((line + "\n").data(using: .utf8)!)
        } else {
            try (line + "\n").write(to: jsonlPath, atomically: false, encoding: .utf8)
        }

        try updateStorageMetadata(for: session, appendedMessage: message)

    }

    func getCachedMessages(sessionId: String, limit: Int?, offset: Int?) async throws -> [SessionMessage] {
        guard let session = try await getSession(id: sessionId) else {
            throw SessionRepositoryError.sessionNotFound
        }
        let jsonlPath = messagesPath(for: session)

        guard fileManager.fileExists(atPath: jsonlPath.path) else {
            return []  // 无缓存
        }
        let start = max(0, offset ?? 0)
        let requestedLimit = limit

        return try await runOnMessageReadQueue {
            let content = try String(contentsOfFile: jsonlPath.path, encoding: .utf8)
            let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
            guard start < lines.count else { return [] }

            let endExclusive = requestedLimit.map { start + max(0, $0) } ?? lines.count
            let safeEnd = min(endExclusive, lines.count)
            guard start < safeEnd else { return [] }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var result: [SessionMessage] = []
            result.reserveCapacity(safeEnd - start)

            for line in lines[start..<safeEnd] {
                guard let data = line.data(using: .utf8),
                      let message = try? decoder.decode(SessionMessage.self, from: data) else {
                    continue
                }
                result.append(message)
            }
            return result
        }
    }

    func getCachedMessagesTail(
        sessionId: String,
        limit: Int,
        beforeTailCount: Int = 0
    ) async throws -> [SessionMessage] {
        guard let session = try await getSession(id: sessionId) else {
            throw SessionRepositoryError.sessionNotFound
        }
        guard limit > 0 else { return [] }

        let jsonlPath = messagesPath(for: session)
        guard fileManager.fileExists(atPath: jsonlPath.path) else {
            return []
        }

        let safeBefore = max(0, beforeTailCount)
        let safeLimit = max(0, limit)

        return try await runOnMessageReadQueue {
            let lines = try self.readJSONLLinesFromTail(
                at: jsonlPath,
                limit: safeLimit,
                skipTailLines: safeBefore
            )
            guard !lines.isEmpty else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601

            var result: [SessionMessage] = []
            result.reserveCapacity(lines.count)

            for line in lines {
                guard let data = line.data(using: .utf8),
                      let message = try? decoder.decode(SessionMessage.self, from: data) else {
                    continue
                }
                result.append(message)
            }
            return result
        }
    }

    private func runOnMessageReadQueue<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            messageReadQueue.async {
                do {
                    let value = try operation()
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func readJSONLLinesFromTail(
        at fileURL: URL,
        limit: Int,
        skipTailLines: Int
    ) throws -> [String] {
        guard limit > 0 else { return [] }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard !data.isEmpty else { return [] }

        let newline: UInt8 = 0x0A
        var index = data.count
        var lineEnd = data.count
        var skipped = 0
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(limit)

        while index > 0 {
            index -= 1
            if data[index] != newline {
                continue
            }

            let start = index + 1
            let end = lineEnd
            if start < end {
                if skipped < skipTailLines {
                    skipped += 1
                } else if ranges.count < limit {
                    ranges.append(start..<end)
                } else {
                    break
                }
            }
            lineEnd = index
        }

        if ranges.count < limit, lineEnd > 0 {
            let start = 0
            let end = lineEnd
            if start < end {
                if skipped < skipTailLines {
                    // nothing
                } else {
                    ranges.append(start..<end)
                }
            }
        }

        guard !ranges.isEmpty else { return [] }

        var lines: [String] = []
        lines.reserveCapacity(ranges.count)

        for range in ranges.reversed() {
            var lineData = data.subdata(in: range)
            if let last = lineData.last, last == 0x0D {
                lineData.removeLast()
            }
            guard !lineData.isEmpty else { continue }
            guard let line = String(data: lineData, encoding: .utf8),
                  !line.isEmpty else {
                continue
            }
            lines.append(line)
        }

        return lines
    }

    private func stableRawMessageId(from message: SessionMessage) -> String? {
        guard let raw = message.metadata?["rawMessageId"]?.value as? String,
              !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func isLikelyDuplicateMessage(_ lhs: SessionMessage, _ rhs: SessionMessage) -> Bool {
        guard lhs.role == rhs.role, lhs.content == rhs.content else {
            return false
        }

        let lhsMs = Int64(lhs.timestamp.timeIntervalSince1970 * 1000)
        let rhsMs = Int64(rhs.timestamp.timeIntervalSince1970 * 1000)
        if abs(lhsMs - rhsMs) > 1000 {
            return false
        }

        if lhs.toolCalls != nil || rhs.toolCalls != nil {
            let lhsTools = lhs.toolCalls?.map { "\($0.id)|\($0.name)" }.joined(separator: ",") ?? ""
            let rhsTools = rhs.toolCalls?.map { "\($0.id)|\($0.name)" }.joined(separator: ",") ?? ""
            if lhsTools != rhsTools {
                return false
            }
        }

        return true
    }

    func clearMessageCache(sessionId: String, notifyCloud: Bool = true) async throws {
        _ = notifyCloud // 保留接口参数，当前阶段仅本地落盘
        guard let session = try await getSession(id: sessionId) else {
            throw SessionRepositoryError.sessionNotFound
        }

        try removeSessionDirectory(for: session)
        print("🗑️ Cleared cache for session: \(sessionId)")

    }

    // MARK: - Helpers

    private func messagesPath(for session: ContextGoSession) -> URL {
        let mirrorPath = SessionStorageLayout.messagesFileURL(
            baseDirectory: sessionsDirectory,
            agentId: session.agentId,
            sessionId: session.id
        )
        if fileManager.fileExists(atPath: mirrorPath.path) {
            return mirrorPath
        }

        let legacyPath = SessionStorageLayout.legacyMessagesFileURL(
            baseDirectory: sessionsDirectory,
            agentId: session.agentId,
            sessionId: session.id
        )
        if fileManager.fileExists(atPath: legacyPath.path) {
            return legacyPath
        }

        return mirrorPath
    }

    private func providerSessionId(from session: ContextGoSession) -> String? {
        guard let metadata = session.channelMetadataDict else { return nil }
        if let key = metadata["sessionKey"] as? String, !key.isEmpty { return key }
        if let cliSessionId = metadata["cliSessionId"] as? String, !cliSessionId.isEmpty { return cliSessionId }
        return nil
    }

    private func providerName(from session: ContextGoSession) -> String {
        if session.tags.contains("cli") { return "cli" }
        if session.tags.contains("openclaw") { return "openclaw" }
        if let flavor = session.channelMetadataDict?["flavor"] as? String, !flavor.isEmpty { return flavor }
        return "unknown"
    }

    private func upsertStorageMetadata(for session: ContextGoSession) throws {
        let metadataURL = SessionStorageLayout.metadataFileURL(
            baseDirectory: sessionsDirectory,
            agentId: session.agentId,
            sessionId: session.id
        )
        let metadataDir = metadataURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: metadataDir.path) {
            try fileManager.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        }

        var stats = SessionStorageMetadata.MessageStats.empty
        let messagesURL = messagesPath(for: session)
        if fileManager.fileExists(atPath: messagesURL.path) {
            let cachedMessages = try parseMessages(at: messagesURL)
            stats = buildStats(from: cachedMessages)
        }

        let metadata = SessionStorageMetadata(
            schemaVersion: 1,
            sessionResourceURI: SessionStorageLayout.sessionResourceURI(agentId: session.agentId, sessionId: session.id),
            contextGoSessionId: session.id,
            agentId: session.agentId,
            provider: providerName(from: session),
            providerSessionId: providerSessionId(from: session),
            title: session.title,
            preview: session.preview,
            tags: session.tags,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            lastMessageTime: session.lastMessageTime,
            syncStatus: session.syncStatus.rawValue,
            lastSyncAt: session.lastSyncAt,
            channelMetadataRaw: session.channelMetadata,
            stats: stats
        )

        let data = try metadataEncoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func updateStorageMetadata(for session: ContextGoSession, appendedMessage: SessionMessage) throws {
        let metadataURL = SessionStorageLayout.metadataFileURL(
            baseDirectory: sessionsDirectory,
            agentId: session.agentId,
            sessionId: session.id
        )

        var metadata: SessionStorageMetadata
        if fileManager.fileExists(atPath: metadataURL.path),
           let data = try? Data(contentsOf: metadataURL),
           let decoded = try? metadataDecoder.decode(SessionStorageMetadata.self, from: data) {
            metadata = decoded
        } else {
            metadata = SessionStorageMetadata(
                schemaVersion: 1,
                sessionResourceURI: SessionStorageLayout.sessionResourceURI(agentId: session.agentId, sessionId: session.id),
                contextGoSessionId: session.id,
                agentId: session.agentId,
                provider: providerName(from: session),
                providerSessionId: providerSessionId(from: session),
                title: session.title,
                preview: session.preview,
                tags: session.tags,
                createdAt: session.createdAt,
                updatedAt: session.updatedAt,
                lastMessageTime: session.lastMessageTime,
                syncStatus: session.syncStatus.rawValue,
                lastSyncAt: session.lastSyncAt,
                channelMetadataRaw: session.channelMetadata,
                stats: .empty
            )
        }

        metadata.title = session.title
        metadata.preview = session.preview
        metadata.tags = session.tags
        metadata.updatedAt = session.updatedAt
        metadata.lastMessageTime = session.lastMessageTime
        metadata.syncStatus = session.syncStatus.rawValue
        metadata.lastSyncAt = session.lastSyncAt
        metadata.channelMetadataRaw = session.channelMetadata

        metadata.stats.total += 1
        metadata.stats.totalCharacters += appendedMessage.content.count
        metadata.stats.lastMessageAt = appendedMessage.timestamp
        switch appendedMessage.role {
        case .user: metadata.stats.user += 1
        case .assistant: metadata.stats.assistant += 1
        case .system: metadata.stats.system += 1
        case .tool: metadata.stats.tool += 1
        }

        let metadataDir = metadataURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: metadataDir.path) {
            try fileManager.createDirectory(at: metadataDir, withIntermediateDirectories: true)
        }

        let data = try metadataEncoder.encode(metadata)
        try data.write(to: metadataURL, options: .atomic)
    }

    private func parseMessages(at fileURL: URL) throws -> [SessionMessage] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return lines.compactMap { line in
            guard let data = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(SessionMessage.self, from: data)
        }
    }

    private func rewriteMessages(_ messages: [SessionMessage], to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = try messages.map { message -> String in
            let data = try encoder.encode(message)
            guard let line = String(data: data, encoding: .utf8) else {
                throw SessionRepositoryError.encodingFailed
            }
            return line
        }

        let payload = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try payload.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func buildStats(from messages: [SessionMessage]) -> SessionStorageMetadata.MessageStats {
        var stats = SessionStorageMetadata.MessageStats.empty
        for message in messages {
            stats.total += 1
            stats.totalCharacters += message.content.count
            stats.lastMessageAt = message.timestamp
            switch message.role {
            case .user: stats.user += 1
            case .assistant: stats.assistant += 1
            case .system: stats.system += 1
            case .tool: stats.tool += 1
            }
        }
        return stats
    }

    private func removeSessionDirectory(for session: ContextGoSession) throws {
        let sessionDir = SessionStorageLayout.sessionDirectoryURL(
            baseDirectory: sessionsDirectory,
            agentId: session.agentId,
            sessionId: session.id
        )
        if fileManager.fileExists(atPath: sessionDir.path) {
            try fileManager.removeItem(at: sessionDir)
        }

        let legacySessionDir = SessionStorageLayout.legacySessionDirectoryURL(
            baseDirectory: sessionsDirectory,
            agentId: session.agentId,
            sessionId: session.id
        )
        if fileManager.fileExists(atPath: legacySessionDir.path) {
            try fileManager.removeItem(at: legacySessionDir)
        }
    }

    private func migrateLegacySessionLayoutIfNeeded() {
        let legacyAgentsRoot = sessionsDirectory.appendingPathComponent("agents", isDirectory: true)
        guard fileManager.fileExists(atPath: legacyAgentsRoot.path) else {
            return
        }

        do {
            let agentDirs = try fileManager.contentsOfDirectory(
                at: legacyAgentsRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )

            for agentDir in agentDirs {
                let isAgentDir = (try agentDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                if !isAgentDir {
                    continue
                }
                let sessionDirs = try fileManager.contentsOfDirectory(
                    at: agentDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )

                for legacySessionDir in sessionDirs {
                    let isSessionDir = (try legacySessionDir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    if !isSessionDir {
                        continue
                    }
                    let targetSessionDir = sessionsDirectory
                        .appendingPathComponent("users", isDirectory: true)
                        .appendingPathComponent(SessionStorageLayout.encodePathComponent(SessionStorageLayout.defaultLocalUserId), isDirectory: true)
                        .appendingPathComponent("sessions", isDirectory: true)
                        .appendingPathComponent(agentDir.lastPathComponent, isDirectory: true)
                        .appendingPathComponent(legacySessionDir.lastPathComponent, isDirectory: true)

                    let targetParent = targetSessionDir.deletingLastPathComponent()
                    if !fileManager.fileExists(atPath: targetParent.path) {
                        try fileManager.createDirectory(at: targetParent, withIntermediateDirectories: true)
                    }

                    if fileManager.fileExists(atPath: targetSessionDir.path) {
                        let items = try fileManager.contentsOfDirectory(
                            at: legacySessionDir,
                            includingPropertiesForKeys: nil,
                            options: [.skipsHiddenFiles]
                        )
                        for item in items {
                            let targetItem = targetSessionDir.appendingPathComponent(item.lastPathComponent)
                            if !fileManager.fileExists(atPath: targetItem.path) {
                                try fileManager.moveItem(at: item, to: targetItem)
                            }
                        }
                        try fileManager.removeItem(at: legacySessionDir)
                    } else {
                        try fileManager.moveItem(at: legacySessionDir, to: targetSessionDir)
                    }

                    let legacyHeadFile = targetSessionDir.appendingPathComponent("metadata.json")
                    let mirrorHeadFile = targetSessionDir.appendingPathComponent("head.json")
                    if fileManager.fileExists(atPath: legacyHeadFile.path) && !fileManager.fileExists(atPath: mirrorHeadFile.path) {
                        try fileManager.moveItem(at: legacyHeadFile, to: mirrorHeadFile)
                    }
                }
            }

            if let remaining = try? fileManager.contentsOfDirectory(atPath: legacyAgentsRoot.path), remaining.isEmpty {
                try? fileManager.removeItem(at: legacyAgentsRoot)
            }
            print("✅ SessionRepository migrated legacy session layout to storage-provider mirror")
        } catch {
            print("⚠️ SessionRepository legacy layout migration skipped: \(error)")
        }
    }
}

// MARK: - Errors

enum SessionRepositoryError: Error, LocalizedError {
    case databaseNotInitialized
    case sessionNotFound
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .databaseNotInitialized:
            return "数据库未初始化"
        case .sessionNotFound:
            return "Session 不存在"
        case .encodingFailed:
            return "消息编码失败"
        }
    }
}
