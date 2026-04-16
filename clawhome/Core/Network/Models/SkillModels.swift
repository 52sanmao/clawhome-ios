//
//  SkillModels.swift
//  contextgo
//
//  OpenClaw Skills Protocol Models
//

import Foundation

// MARK: - Skill Status Request

struct SkillsStatusRequest: Codable {
    let type: String = "req"
    let id: String
    let method: String = "skills.status"
    let params: Params

    struct Params: Codable {
        let agentId: String?
    }
}

// MARK: - Skill Status Response

struct SkillsStatusResponse: Codable {
    let type: String
    let id: String
    let ok: Bool
    let payload: Payload?
    let error: ErrorPayload?

    struct Payload: Codable {
        let workspaceDir: String
        let managedSkillsDir: String
        let skills: [Skill]
    }

    struct ErrorPayload: Codable {
        let message: String
        let code: String?
    }
}

// MARK: - Skill Model (matches current backend response)

struct Skill: Codable, Identifiable {
    let name: String
    let description: String
    let source: String  // "openclaw-workspace", "openclaw-bundled", "openclaw-managed"
    let bundled: Bool?  // 改为可选
    let filePath: String
    let baseDir: String?  // 改为可选
    let skillKey: String
    let emoji: String?
    let homepage: String?
    let always: Bool
    let disabled: Bool
    let blockedByAllowlist: Bool?  // 改为可选
    let eligible: Bool?  // 改为可选
    let requirements: SkillRequirements
    let missing: SkillRequirements
    let primaryEnv: String?  // ✅ NEW: Primary environment variable name (e.g., "SLACK_TOKEN")
    // configChecks 是字典数组，UI 不使用，忽略解码
    let install: [SkillInstallConfig]?  // 改为可选

    var id: String { skillKey }

    // 自定义解码器，跳过 configChecks
    enum CodingKeys: String, CodingKey {
        case name, description, source, bundled, filePath, baseDir, skillKey
        case emoji, homepage, always, disabled, blockedByAllowlist, eligible
        case requirements, missing, primaryEnv, install
        // 不包含 configChecks，解码时会自动忽略
    }

}

// MARK: - Skill Requirements (matches actual response)

struct SkillRequirements: Codable {
    let bins: [String]
    let anyBins: [String]?  // 改为可选，UI 不使用
    let env: [String]?      // 改为可选，UI 不使用
    let config: [String]?   // 改为可选，UI 不使用
    let os: [String]?       // 改为可选，UI 不使用

    // 提供解码初始化器，未提供的字段使用空数组
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bins = try container.decodeIfPresent([String].self, forKey: .bins) ?? []
        anyBins = try container.decodeIfPresent([String].self, forKey: .anyBins)
        env = try container.decodeIfPresent([String].self, forKey: .env)
        config = try container.decodeIfPresent([String].self, forKey: .config)
        os = try container.decodeIfPresent([String].self, forKey: .os)
    }
}

// MARK: - Skill Install Config (matches actual response)

struct SkillInstallConfig: Codable {
    let id: String
    let kind: String
    let label: String
    let bins: [String]?
}

// MARK: - Skill Update Request

struct SkillUpdateRequest: Codable {
    let type: String = "req"
    let id: String
    let method: String = "skills.update"
    let params: Params

    struct Params: Codable {
        let skillKey: String
        let enabled: Bool?
        let apiKey: String?
        let env: [String: String]?
    }
}

// MARK: - Skill Update Response

struct SkillUpdateResponse: Codable {
    let type: String
    let id: String
    let ok: Bool
    let payload: Payload?
    let error: ErrorPayload?

    struct Payload: Codable {
        let ok: Bool
        let skillKey: String
        let config: SkillConfig?
    }

    struct SkillConfig: Codable {
        let enabled: Bool?
        let apiKey: String?
        let env: [String: String]?
    }

    struct ErrorPayload: Codable {
        let message: String
        let code: String?
    }
}
