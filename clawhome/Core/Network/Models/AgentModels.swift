//
//  AgentModels.swift
//  contextgo
//
//  Agent 数据模型（Core API）
//

import Foundation

// MARK: - Agent 基础模型

/// Agent 数据（Core 管理）
struct CloudAgent: Codable, Identifiable {
    var id: String
    var name: String                // 唯一标识名
    var displayName: String         // 显示名称
    var description: String?
    var avatar: String?             // 头像标识

    // Agent 类型和配置
    var type: String                // 'openclaw', 'claudecode', 'codex', 'geminicli', 'opencode'
    var config: String              // JSON 字符串：连接配置
    var permissions: String         // JSON 字符串：权限配置

    var callbackUrl: String?

    var status: String              // 'active', 'inactive'
    var createdAt: Date
    var updatedAt: Date

    // MARK: - Custom Decoding

    enum CodingKeys: String, CodingKey {
        case id, name, displayName, description, avatar
        case type, config, permissions, callbackUrl, status
        case createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        displayName = try container.decode(String.self, forKey: .displayName)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        avatar = try container.decodeIfPresent(String.self, forKey: .avatar)
        type = try container.decode(String.self, forKey: .type)
        callbackUrl = try container.decodeIfPresent(String.self, forKey: .callbackUrl)
        status = try container.decode(String.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)

        // Handle config: can be String or Dictionary
        if let configString = try? container.decode(String.self, forKey: .config) {
            config = configString
        } else {
            // Try to decode as any type and convert to JSON string
            let configData = try container.decode(AnyCodableValue.self, forKey: .config)
            if let jsonData = try? JSONSerialization.data(withJSONObject: configData.value, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                config = jsonString
            } else {
                config = "{}"
            }
        }

        // Handle permissions: can be String or Dictionary
        if let permString = try? container.decode(String.self, forKey: .permissions) {
            permissions = permString
        } else {
            // Try to decode as any type and convert to JSON string
            let permData = try container.decode(AnyCodableValue.self, forKey: .permissions)
            if let jsonData = try? JSONSerialization.data(withJSONObject: permData.value, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                permissions = jsonString
            } else {
                permissions = "{}"
            }
        }
    }

    // MARK: - Manual Initializer for Preview/Test

    init(
        id: String,
        name: String,
        displayName: String,
        description: String? = nil,
        avatar: String? = nil,
        type: String,
        config: String,
        permissions: String,
        callbackUrl: String? = nil,
        status: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName
        self.description = description
        self.avatar = avatar
        self.type = type
        self.config = config
        self.permissions = permissions
        self.callbackUrl = callbackUrl
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: - Helper Methods

    /// 解析 config JSON
    func parseConfig<T: Decodable>() throws -> T {
        guard let data = config.data(using: .utf8) else {
            throw AgentError.invalidConfig
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// 解析 OpenClaw 配置
    func openClawConfig() throws -> OpenClawConfig {
        return try parseConfig()
    }

    /// 解析 CLI Relay 配置
    func cliRelayConfig() throws -> CLIRelayConfig {
        return try parseConfig()
    }

    /// 解析 permissions JSON
    func parsePermissions() throws -> AgentPermissions {
        guard let data = permissions.data(using: .utf8) else {
            throw AgentError.invalidPermissions
        }
        return try JSONDecoder().decode(AgentPermissions.self, from: data)
    }

}

// MARK: - Config 类型定义（用于解析 config JSON）

/// OpenClaw Agent 配置
struct OpenClawConfig: Codable {
    var wsURL: String
    var token: String?
    var agentId: String?  // Optional - can be derived from CloudAgent.id if not provided
    var sessionKey: String?

    enum CodingKeys: String, CodingKey {
        case wsURL
        case gatewayURL  // Alias for wsURL (backend compatibility)
        case token
        case agentId
        case sessionKey
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Try wsURL first, fallback to gatewayURL
        if let wsURL = try? container.decode(String.self, forKey: .wsURL) {
            self.wsURL = wsURL
        } else if let gatewayURL = try? container.decode(String.self, forKey: .gatewayURL) {
            self.wsURL = gatewayURL
        } else {
            throw DecodingError.keyNotFound(
                CodingKeys.wsURL,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Neither wsURL nor gatewayURL found"
                )
            )
        }

        self.token = try? container.decode(String.self, forKey: .token)
        self.agentId = try? container.decode(String.self, forKey: .agentId)
        self.sessionKey = try? container.decode(String.self, forKey: .sessionKey)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(wsURL, forKey: .wsURL)
        try container.encodeIfPresent(token, forKey: .token)
        try container.encodeIfPresent(agentId, forKey: .agentId)
        try container.encodeIfPresent(sessionKey, forKey: .sessionKey)
    }
}

/// CLI Relay Agent 配置
struct CLIRelayConfig: Codable {
    var serverURL: String
    var machineId: String?
    var encryptionEnabled: Bool?
    var token: String?              // JWT token
    var secretKey: String?          // Base64 encoded master secret key
}

// MARK: - Permissions 类型定义（用于解析 permissions JSON）

struct AgentPermissions: Codable {
    var allowedSpaces: [String]
    var allowedActions: [String]?
}

// MARK: - Helper Types

/// 动态 CodingKey 用于编码任意字典
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ string: String) {
        self.stringValue = string
        self.intValue = nil
    }

    init(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

// MARK: - Errors

enum AgentError: LocalizedError {
    case invalidConfig
    case invalidPermissions

    var errorDescription: String? {
        switch self {
        case .invalidConfig:
            return "Invalid agent config JSON"
        case .invalidPermissions:
            return "Invalid agent permissions JSON"
        }
    }
}

// MARK: - AnyCodable Helper

/// Helper to decode any JSON value (String, Int, Bool, Array, Dictionary)
struct AnyCodableValue: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let string = try? container.decode(String.self) {
            value = string
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let array = try? container.decode([AnyCodableValue].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodableValue].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }
}
