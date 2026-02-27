//
//  AgentService.swift
//  contextgo
//
//  Agent 服务层 — 使用 Core API
//

import Foundation

@MainActor
class AgentService: ObservableObject {
    static let shared = AgentService()

    private let coreClient = CoreAPIClient.shared
    private init() {}

    // MARK: - Agent CRUD

    /// 获取用户所有 Agent
    func fetchAgents() async throws -> [CloudAgent] {
        return try await coreClient.listAgents()
    }

    /// 获取单个 Agent 详情
    func fetchAgent(id: String) async throws -> CloudAgent {
        return try await coreClient.getAgent(id: id)
    }

    /// 创建新 Agent
    func createAgent(
        name: String,
        displayName: String,
        description: String? = nil,
        avatar: String? = nil,
        type: String,
        config: [String: Any]? = nil,
        permissions: [String: Any]? = nil,
        callbackUrl: String? = nil
    ) async throws -> CloudAgent {
        do {
            let agent = try await coreClient.createAgent(
                name: name,
                displayName: displayName,
                description: description,
                avatar: avatar,
                type: type,
                config: config,
                permissions: permissions,
                callbackUrl: callbackUrl
            )
            return agent
        } catch {
            print("❌ [AgentService] Creation failed: \(error)")
            throw error
        }
    }

    /// 更新 Agent 信息
    func updateAgent(
        id: String,
        displayName: String? = nil,
        description: String? = nil,
        avatar: String? = nil,
        config: [String: Any]? = nil,
        permissions: [String: Any]? = nil,
        callbackUrl: String? = nil
    ) async throws -> CloudAgent {
        do {
            let agent = try await coreClient.updateAgent(
                id: id,
                displayName: displayName,
                description: description,
                avatar: avatar,
                config: config,
                permissions: permissions,
                callbackUrl: callbackUrl
            )
            return agent
        } catch {
            print("❌ [AgentService] Update failed: \(error)")
            throw error
        }
    }

    /// 删除 Agent
    func deleteAgent(id: String) async throws {
        try await coreClient.deleteAgent(id: id)
    }
}
