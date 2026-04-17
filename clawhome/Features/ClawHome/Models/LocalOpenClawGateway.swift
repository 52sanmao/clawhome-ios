import Foundation

struct LocalOpenClawGateway: Codable, Identifiable, Hashable {
    let id: String
    var name: String
    var wsURL: String
    var token: String
    let createdAt: Date
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, wsURL, token, createdAt, updatedAt
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        wsURL: String,
        token: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.wsURL = wsURL
        self.token = token
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        wsURL = try container.decode(String.self, forKey: .wsURL)
        token = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }

    var cloudAgent: CloudAgent {
        let configObject: [String: String] = [
            "wsURL": wsURL,
            "token": token,
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
