import Foundation

struct SessionModel: Identifiable {
    let id: String
    let agentId: String

    let title: String
    let timeString: String
    let date: Date
    let preview: String

    let agent: CloudAgent
    let agentChannelType: AgentChannelType
    let sessionMetadata: SessionMetadata?
}

struct SessionMetadata {
    var path: String?
    var pathBasename: String?
    var machineId: String?
    var host: String?
    var hostPid: Int?
    var customTitle: String?
    var aiProvider: String?
    var homeDir: String?
    var claudeSessionId: String?
    var codexSessionId: String?
    var opencodeSessionId: String?
    var geminiSessionId: String?
    var rawJSON: String?
}
