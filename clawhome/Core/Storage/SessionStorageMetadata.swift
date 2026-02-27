import Foundation

struct SessionStorageMetadata: Codable {
    var schemaVersion: Int
    var sessionResourceURI: String
    var contextGoSessionId: String
    var agentId: String
    var provider: String
    var providerSessionId: String?
    var title: String
    var preview: String
    var tags: [String]
    var createdAt: Date
    var updatedAt: Date
    var lastMessageTime: Date
    var syncStatus: String
    var lastSyncAt: Date?
    var channelMetadataRaw: String?
    var stats: MessageStats

    struct MessageStats: Codable {
        var total: Int
        var user: Int
        var assistant: Int
        var system: Int
        var tool: Int
        var totalCharacters: Int
        var lastMessageAt: Date?

        static let empty = MessageStats(
            total: 0,
            user: 0,
            assistant: 0,
            system: 0,
            tool: 0,
            totalCharacters: 0,
            lastMessageAt: nil
        )
    }
}
