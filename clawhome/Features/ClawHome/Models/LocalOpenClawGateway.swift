import Foundation

struct LocalOpenClawGateway: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var wsURL: String
    let createdAt: Date
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        wsURL: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.wsURL = wsURL
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var cloudAgent: CloudAgent {
        let configObject: [String: String] = [
            "wsURL": wsURL,
            "agentId": id
        ]

        let configData = try? JSONSerialization.data(withJSONObject: configObject, options: [])
        let configString = configData.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return CloudAgent(
            id: id,
            name: "openclaw-\(id.prefix(8))",
            displayName: name,
            description: "IronClaw endpoint",
            avatar: "OpenClawLogo",
            type: "openclaw",
            config: configString,
            permissions: "{}",
            callbackUrl: nil,
            status: "active",
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
