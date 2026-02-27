//
//  HomeViewModel.swift
//  contextgo
//
//  Home screen ViewModel - 使用云端 Agent 管理
//

import Foundation
import Combine

@MainActor
class HomeViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var showChatView: Bool = false
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var showConnectingTransition: Bool = false
    @Published var isLoading: Bool = false

    // Agent management - 使用云端 CloudAgent
    @Published var agents: [CloudAgent] = []
    @Published var selectedAgent: CloudAgent?

    // MARK: - Dependencies
    private let connectionManager = ConnectionManager.shared
    private let agentService = AgentService.shared
    private let authService = AuthService.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization
    init() {
        setupBindings()
        setupAuthObserver()

        // 只在已经登录的情况下加载 Agents
        if authService.isAuthenticated {
            Task {
                await loadAgents()
            }
        }
    }

    // MARK: - Setup

    private func setupAuthObserver() {
        // 监听认证状态变化，登录成功后自动加载 Agents
        authService.$isAuthenticated
            .dropFirst() // 跳过初始值，避免重复加载
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAuthenticated in
                if isAuthenticated {
                    print("🔐 [HomeViewModel] 用户已登录，加载 Agents")
                    Task {
                        await self?.loadAgents()
                    }
                } else {
                    print("🔓 [HomeViewModel] 用户已登出，清空 Agents")
                    self?.agents = []
                }
            }
            .store(in: &cancellables)
    }

    private func setupBindings() {
        // Monitor connection states for all agents
        connectionManager.$connectionStates
            .receive(on: DispatchQueue.main)
            .sink { [weak self] states in
                self?.updateAgentsConnectionStatus(states: states)
            }
            .store(in: &cancellables)
    }

    private func updateAgentsConnectionStatus(states: [String: ConnectionState]) {
        // Update each agent's connection status based on ConnectionManager state
        // Note: CloudAgent 没有本地 connectionStatus 字段，状态由 ConnectionManager 管理
        // UI 层可以通过 ConnectionManager.connectionStates[agentId] 获取状态
    }

    // MARK: - Actions
    func selectAgent(_ agent: CloudAgent) {
        selectedAgent = agent

        // Show connecting transition animation
        showConnectingTransition = true

        // ✅ Each agent has its own connection via ConnectionManager
        // No need to manually connect here - ChatViewModel will handle it

        // Delay navigation to show transition animation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showConnectingTransition = false
            self?.showChatView = true
        }
    }

    // MARK: - Agent Management (云端同步)

    /// 从 Core 加载所有 Agent
    func loadAgents() async {
        // 检查 Core 认证状态，未登录则跳过
        guard authService.isAuthenticated else {
            print("ℹ️ [HomeViewModel] 未登录，跳过加载 Agent")
            agents = []
            return
        }

        // 检查 Core 连接配置
        guard CoreConfig.shared.isConfigured else {
            print("ℹ️ [HomeViewModel] Core 未配置，跳过加载 Agent")
            agents = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            agents = try await agentService.fetchAgents()
            print("✅ [HomeViewModel] 已加载 \(agents.count) 个 Agent")
        } catch {
            print("❌ [HomeViewModel] 加载 Agent 失败: \(error)")
            agents = []
        }
    }

    /// 创建新 Agent（云端）
    func createAgent(
        name: String,
        displayName: String,
        description: String? = nil,
        avatar: String? = nil,
        type: String,
        config: [String: Any]
    ) async -> CloudAgent? {
        isLoading = true
        defer { isLoading = false }

        do {
            let agent = try await agentService.createAgent(
                name: name,
                displayName: displayName,
                description: description,
                avatar: avatar,
                type: type,
                config: config
            )
            agents.append(agent)
            return agent
        } catch {
            errorMessage = "创建 Agent 失败: \(error.localizedDescription)"
            showError = true
            print("❌ [HomeViewModel] 创建 Agent 失败: \(error)")
            return nil
        }
    }

    /// 更新 Agent（云端）
    func updateAgent(
        id: String,
        displayName: String? = nil,
        description: String? = nil,
        avatar: String? = nil,
        config: [String: Any]? = nil
    ) async {
        isLoading = true
        defer { isLoading = false }

        do {
            let updatedAgent = try await agentService.updateAgent(
                id: id,
                displayName: displayName,
                description: description,
                avatar: avatar,
                config: config
            )

            if let index = agents.firstIndex(where: { $0.id == id }) {
                agents[index] = updatedAgent
                if selectedAgent?.id == id {
                    selectedAgent = updatedAgent
                }
            } else {
                print("⚠️ [HomeViewModel] Agent updated but not found in local array")
            }
        } catch {
            errorMessage = "更新 Agent 失败: \(error.localizedDescription)"
            showError = true
            print("❌ [HomeViewModel] 更新 Agent 失败: \(id) - \(error)")
        }
    }

    /// 删除 Agent（云端 + 本地清理）
    func removeAgent(_ agent: CloudAgent) async {
        isLoading = true
        defer { isLoading = false }

        do {
            // 1. 云端删除
            try await agentService.deleteAgent(id: agent.id)
            print("✅ [HomeViewModel] 云端已删除 Agent: \(agent.displayName)")

            let sessionRepository = LocalSessionRepository.shared
            let sessions = try await sessionRepository.getAllSessionsIncludingArchived(agentId: agent.id)
            for session in sessions {
                try await sessionRepository.deleteSession(id: session.id)
            }
            print("🗑️ [HomeViewModel] 已删除 Agent \(agent.displayName) 的 \(sessions.count) 个会话")

            connectionManager.removeClient(agentId: agent.id)
            print("🔌 [HomeViewModel] 已断开与 Agent \(agent.displayName) 的连接")

            if selectedAgent?.id == agent.id {
                selectedAgent = nil
            }

            agents.removeAll { $0.id == agent.id }
            print("✅ [HomeViewModel] Agent \(agent.displayName) 已完全删除")

            NotificationCenter.default.post(
                name: NSNotification.Name("AgentDeleted"),
                object: nil,
                userInfo: ["agentId": agent.id]
            )

        } catch {
            errorMessage = "删除 Agent 失败: \(error.localizedDescription)"
            showError = true
            print("❌ [HomeViewModel] 删除 Agent 失败: \(error)")
        }
    }

    /// 更新 Agent 名称
    func updateAgentName(_ agent: CloudAgent, newName: String) async {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }
        if trimmedName == agent.displayName { return }

        await updateAgent(id: agent.id, displayName: trimmedName)
    }

    /// 刷新 Agent 列表（下拉刷新）
    func refreshAgents() async {
        await loadAgents()
    }
}
