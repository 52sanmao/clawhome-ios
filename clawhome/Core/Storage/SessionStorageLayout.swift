import Foundation

enum SessionStorageLayout {
    static let scheme = "ctxgo"
    static let sessionHost = "session"
    static let usersHost = "users"
    static let defaultLocalUserId = "local"

    static func encodePathComponent(_ raw: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return raw.addingPercentEncoding(withAllowedCharacters: allowed) ?? raw
    }

    static func decodePathComponent(_ encoded: String) -> String {
        encoded.removingPercentEncoding ?? encoded
    }

    static func sessionResourceURI(agentId: String, sessionId: String) -> String {
        let encodedAgentId = encodePathComponent(agentId)
        let encodedSessionId = encodePathComponent(sessionId)
        return "\(scheme)://\(sessionHost)/\(encodedAgentId)/\(encodedSessionId)"
    }

    static func parseSessionResourceURI(_ uri: String) -> (agentId: String, sessionId: String)? {
        guard let components = URLComponents(string: uri) else { return nil }
        guard components.scheme == scheme, components.host == sessionHost else { return nil }
        let parts = components.path.split(separator: "/")
        guard parts.count >= 2 else { return nil }
        let agentId = decodePathComponent(String(parts[0]))
        let sessionId = decodePathComponent(String(parts[1]))
        return (agentId: agentId, sessionId: sessionId)
    }

    static func attachmentResourceURI(userId: String, attachmentId: String) -> String {
        let encodedUserId = encodePathComponent(userId)
        let encodedAttachmentId = encodePathComponent(attachmentId)
        return "\(scheme)://\(usersHost)/\(encodedUserId)/attachments/\(encodedAttachmentId)"
    }

    static func parseAttachmentResourceURI(_ uri: String) -> (userId: String, attachmentId: String)? {
        guard let components = URLComponents(string: uri) else { return nil }
        guard components.scheme == scheme, components.host == usersHost else { return nil }

        let parts = components.path.split(separator: "/")
        guard parts.count >= 3 else { return nil }
        guard parts[1] == "attachments" else { return nil }

        let userId = decodePathComponent(String(parts[0]))
        let attachmentId = decodePathComponent(String(parts[2]))
        return (userId: userId, attachmentId: attachmentId)
    }

    static func userRelativePath(userId: String = defaultLocalUserId) -> String {
        "users/\(encodePathComponent(userId))"
    }

    static func sessionsRootRelativePath(userId: String = defaultLocalUserId) -> String {
        "\(userRelativePath(userId: userId))/sessions"
    }

    static func attachmentsRootRelativePath(userId: String = defaultLocalUserId) -> String {
        "\(userRelativePath(userId: userId))/attachments"
    }

    static func attachmentObjectsRootRelativePath(userId: String = defaultLocalUserId) -> String {
        "\(attachmentsRootRelativePath(userId: userId))/objects"
    }

    static func attachmentMetaRootRelativePath(userId: String = defaultLocalUserId) -> String {
        "\(attachmentsRootRelativePath(userId: userId))/meta"
    }

    static func hashToObjectPath(_ hash: String) -> String {
        "\(hash.prefix(2))/\(hash.dropFirst(2).prefix(2))/\(hash)"
    }

    static func attachmentObjectRelativePath(userId: String = defaultLocalUserId, sha256: String) -> String {
        "\(attachmentObjectsRootRelativePath(userId: userId))/\(hashToObjectPath(sha256))"
    }

    static func attachmentMetaRelativePath(userId: String = defaultLocalUserId, attachmentId: String) -> String {
        "\(attachmentMetaRootRelativePath(userId: userId))/\(encodePathComponent(attachmentId)).json"
    }

    static func attachmentDateKey(attachmentId: String, createdAt: String? = nil) -> String? {
        let prefixPattern = /^att_(\d{8})_[A-Za-z0-9_-]+$/
        if let match = attachmentId.wholeMatch(of: prefixPattern) {
            return String(match.output.1)
        }

        if let createdAt {
            return String(createdAt.prefix(10)).replacingOccurrences(of: "-", with: "")
        }
        return nil
    }

    static func attachmentObjectRelativePath(
        userId: String = defaultLocalUserId,
        sha256: String,
        dateKey: String
    ) -> String {
        "\(attachmentsRootRelativePath(userId: userId))/\(dateKey)/objects/\(hashToObjectPath(sha256))"
    }

    static func attachmentMetaRelativePath(
        userId: String = defaultLocalUserId,
        attachmentId: String,
        dateKey: String
    ) -> String {
        "\(attachmentsRootRelativePath(userId: userId))/\(dateKey)/meta/\(encodePathComponent(attachmentId)).json"
    }

    static func agentRelativePath(agentId: String, userId: String = defaultLocalUserId) -> String {
        "\(sessionsRootRelativePath(userId: userId))/\(encodePathComponent(agentId))"
    }

    static func sessionRelativePath(agentId: String, sessionId: String, userId: String = defaultLocalUserId) -> String {
        "\(agentRelativePath(agentId: agentId, userId: userId))/\(encodePathComponent(sessionId))"
    }

    static func metadataRelativePath(agentId: String, sessionId: String, userId: String = defaultLocalUserId) -> String {
        "\(sessionRelativePath(agentId: agentId, sessionId: sessionId, userId: userId))/head.json"
    }

    static func messagesRelativePath(agentId: String, sessionId: String, userId: String = defaultLocalUserId) -> String {
        "\(sessionRelativePath(agentId: agentId, sessionId: sessionId, userId: userId))/messages.jsonl"
    }

    static func sessionDirectoryURL(baseDirectory: URL, agentId: String, sessionId: String, userId: String = defaultLocalUserId) -> URL {
        baseDirectory
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(encodePathComponent(userId), isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(encodePathComponent(agentId), isDirectory: true)
            .appendingPathComponent(encodePathComponent(sessionId), isDirectory: true)
    }

    static func metadataFileURL(baseDirectory: URL, agentId: String, sessionId: String, userId: String = defaultLocalUserId) -> URL {
        sessionDirectoryURL(baseDirectory: baseDirectory, agentId: agentId, sessionId: sessionId, userId: userId)
            .appendingPathComponent("head.json")
    }

    static func messagesFileURL(baseDirectory: URL, agentId: String, sessionId: String, userId: String = defaultLocalUserId) -> URL {
        sessionDirectoryURL(baseDirectory: baseDirectory, agentId: agentId, sessionId: sessionId, userId: userId)
            .appendingPathComponent("messages.jsonl")
    }

    static func attachmentObjectFileURL(baseDirectory: URL, userId: String = defaultLocalUserId, sha256: String) -> URL {
        let hashPath = hashToObjectPath(sha256).split(separator: "/").map(String.init)
        var url = baseDirectory
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(encodePathComponent(userId), isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("objects", isDirectory: true)

        for (index, component) in hashPath.enumerated() {
            let isDirectory = index < hashPath.count - 1
            url = url.appendingPathComponent(component, isDirectory: isDirectory)
        }
        return url
    }

    static func attachmentObjectFileURL(
        baseDirectory: URL,
        userId: String = defaultLocalUserId,
        sha256: String,
        dateKey: String
    ) -> URL {
        let hashPath = hashToObjectPath(sha256).split(separator: "/").map(String.init)
        var url = baseDirectory
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(encodePathComponent(userId), isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(dateKey, isDirectory: true)
            .appendingPathComponent("objects", isDirectory: true)

        for (index, component) in hashPath.enumerated() {
            let isDirectory = index < hashPath.count - 1
            url = url.appendingPathComponent(component, isDirectory: isDirectory)
        }
        return url
    }

    static func attachmentMetaFileURL(baseDirectory: URL, userId: String = defaultLocalUserId, attachmentId: String) -> URL {
        baseDirectory
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(encodePathComponent(userId), isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent("meta", isDirectory: true)
            .appendingPathComponent("\(encodePathComponent(attachmentId)).json")
    }

    static func attachmentMetaFileURL(
        baseDirectory: URL,
        userId: String = defaultLocalUserId,
        attachmentId: String,
        dateKey: String
    ) -> URL {
        baseDirectory
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(encodePathComponent(userId), isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(dateKey, isDirectory: true)
            .appendingPathComponent("meta", isDirectory: true)
            .appendingPathComponent("\(encodePathComponent(attachmentId)).json")
    }

    // Legacy v1 layout (before mirror alignment) for migration/fallback.
    static func legacySessionDirectoryURL(baseDirectory: URL, agentId: String, sessionId: String) -> URL {
        baseDirectory
            .appendingPathComponent("agents", isDirectory: true)
            .appendingPathComponent(encodePathComponent(agentId), isDirectory: true)
            .appendingPathComponent(encodePathComponent(sessionId), isDirectory: true)
    }

    static func legacyMetadataFileURL(baseDirectory: URL, agentId: String, sessionId: String) -> URL {
        legacySessionDirectoryURL(baseDirectory: baseDirectory, agentId: agentId, sessionId: sessionId)
            .appendingPathComponent("metadata.json")
    }

    static func legacyMessagesFileURL(baseDirectory: URL, agentId: String, sessionId: String) -> URL {
        legacySessionDirectoryURL(baseDirectory: baseDirectory, agentId: agentId, sessionId: sessionId)
            .appendingPathComponent("messages.jsonl")
    }
}
