//
//  SessionListViewModel.swift
//  contextgo
//
//  ViewModel for CLI relay sessions list (从数据库读取,由 relay 端同步)
//

import Foundation
import Combine

@MainActor
class SessionListViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var activeSessions: [CLISession] = []
    @Published var historicalSessions: [CLISession] = []
    @Published var errorMessage: String?
    @Published var showError: Bool = false
    @Published var isSyncingRemote: Bool = false
    @Published var lastRemoteSyncAt: Date?

    // MARK: - Dependencies
    let client: RelayClient
    private let agent: CloudAgent
    private let connectionManager = ConnectionManager.shared
    private let sessionRepository = LocalSessionRepository.shared
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(agent: CloudAgent) {
        self.agent = agent

        // Get or create CLI relay client from ConnectionManager
        if let relayClient = connectionManager.getRelayClient(for: agent) {
            self.client = relayClient
        } else {
            // Fallback to dummy client if configuration is incomplete
            self.client = RelayClient(
                serverURL: URL(string: CoreServerDefaults.relayServerURL)!,
                token: "invalid",
                botId: agent.id
            )
            errorMessage = "Agent 配置不完整,请重新配对"
            showError = true
        }

        // Load sessions from database
        Task {
            await loadSessionsFromDatabase()
            await syncRemoteSessions()
        }

        // Listen for sync notifications from shared CLI sync sources.
        setupNotificationObservers()
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.publisher(for: NSNotification.Name("CLISessionsSynced"))
            .sink { [weak self] notification in
                guard let self = self,
                      let userInfo = notification.userInfo,
                      let botId = userInfo["botId"] as? String,
                      botId == self.agent.id else {
                    return
                }

                Task { @MainActor in
                    await self.loadSessionsFromDatabase()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name("CLISessionDeleted"))
            .sink { [weak self] notification in
                guard let self,
                      let userInfo = notification.userInfo,
                      let botId = userInfo["botId"] as? String,
                      botId == self.agent.id else {
                    return
                }

                Task { @MainActor in
                    await self.loadSessionsFromDatabase()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name("CLISessionUpdated"))
            .sink { [weak self] notification in
                guard let self,
                      let userInfo = notification.userInfo,
                      let botId = userInfo["botId"] as? String,
                      botId == self.agent.id else {
                    return
                }

                let hasMetadataUpdate = userInfo["hasMetadataUpdate"] as? Bool ?? false
                let hasAgentStateUpdate = userInfo["hasAgentStateUpdate"] as? Bool ?? false
                guard hasMetadataUpdate || hasAgentStateUpdate else { return }

                Task { @MainActor in
                    await self.syncRemoteSessions()
                }
            }
            .store(in: &cancellables)
    }

    private func loadSessionsFromDatabase() async {
        do {
            // CLI 会话列表需要包含已归档会话：
            // 归档仅表示停止会话/停止通信，不代表删除本地会话数据。
            let contextGoSessions = try await sessionRepository.getAllSessionsIncludingArchived(agentId: agent.id)
            print("[SessionListViewModel] 📊 Loaded \(contextGoSessions.count) sessions from DB for agent: \(agent.id.prefix(8))")

            // Convert ContextGoSession to CLISession
            let cliSessions = contextGoSessions.compactMap { session -> CLISession? in
                // Parse channelMetadata for CLI-specific fields
                guard let metadataDict = session.channelMetadataDict,
                      metadataDict["cliSessionId"] != nil else {
                    return nil // Skip non-CLI sessions
                }

                let metadata = reconstructCLIMetadata(from: metadataDict)

                return CLISession(
                    id: metadataDict["cliSessionId"] as? String ?? session.id,
                    seq: 0,
                    createdAt: session.createdAt,
                    updatedAt: session.updatedAt,
                    active: session.isActive,
                    activeAt: session.lastMessageTime,
                    metadata: metadata,
                    agentState: nil,
                    agentStateVersion: 0
                )
            }

            updateSessions(cliSessions)
        } catch {
            print("[SessionListViewModel] ❌ Failed to load sessions: \(error)")
            errorMessage = "加载会话失败"
            showError = true
        }
    }

    private func reconstructCLIMetadata(from metadataDict: [String: Any]) -> CLISession.Metadata? {
        let raw = (metadataDict["rawJSON"] as? String).flatMap(parseJSONObject)

        let path = (raw?["path"] as? String) ?? (metadataDict["path"] as? String)
        guard let path, !path.isEmpty else { return nil }

        let host = (raw?["host"] as? String) ?? "Unknown"
        let hostPid = parseInt(raw?["hostPid"] ?? metadataDict["hostPid"])
        let machineId = (raw?["machineId"] as? String) ?? (metadataDict["machineId"] as? String) ?? ""
        let flavor = (raw?["flavor"] as? String) ?? (metadataDict["flavor"] as? String) ?? (metadataDict["aiProvider"] as? String)
        let homeDir = (raw?["homeDir"] as? String) ?? (metadataDict["homeDir"] as? String) ?? ""
        let version = (raw?["version"] as? String) ?? "unknown"
        let platform = raw?["platform"] as? String
        let claudeSessionId = (raw?["claudeSessionId"] as? String) ?? (metadataDict["claudeSessionId"] as? String)
        let codexSessionId = (raw?["codexSessionId"] as? String) ?? (metadataDict["codexSessionId"] as? String)
        let opencodeSessionId = (raw?["opencodeSessionId"] as? String) ?? (metadataDict["opencodeSessionId"] as? String)
        let geminiSessionId = (raw?["geminiSessionId"] as? String) ?? (metadataDict["geminiSessionId"] as? String)

        let customTitle = (raw?["customTitle"] as? String) ?? (raw?["name"] as? String) ?? (metadataDict["customTitle"] as? String)

        var summary: CLISession.Metadata.Summary? = nil
        if let summaryRaw = raw?["summary"] as? [String: Any],
           let summaryText = summaryRaw["text"] as? String,
           !summaryText.isEmpty {
            summary = CLISession.Metadata.Summary(
                text: summaryText,
                updatedAt: parseDate(summaryRaw["updatedAt"]) ?? Date()
            )
        }

        var gitStatus: CLISession.Metadata.GitStatus? = nil
        if let gitRaw = raw?["gitStatus"] as? [String: Any] {
            gitStatus = CLISession.Metadata.GitStatus(
                branch: gitRaw["branch"] as? String,
                isDirty: gitRaw["isDirty"] as? Bool,
                changedFiles: parseInt(
                    gitRaw["changedFiles"]
                    ?? gitRaw["filesChanged"]
                    ?? gitRaw["files"]
                ),
                addedLines: parseInt(
                    gitRaw["addedLines"]
                    ?? gitRaw["added"]
                    ?? gitRaw["insertions"]
                    ?? gitRaw["additions"]
                ),
                deletedLines: parseInt(
                    gitRaw["deletedLines"]
                    ?? gitRaw["deleted"]
                    ?? gitRaw["deletions"]
                    ?? gitRaw["removals"]
                ),
                upstreamBranch: (gitRaw["upstreamBranch"] as? String) ?? (gitRaw["upstream"] as? String),
                aheadCount: parseInt(gitRaw["aheadCount"] ?? gitRaw["ahead"]),
                behindCount: parseInt(gitRaw["behindCount"] ?? gitRaw["behind"])
            )
        }

        let runtimeRaw = (raw?["runtime"] as? [String: Any]) ?? (metadataDict["runtime"] as? [String: Any])
        var runtime: CLISession.Metadata.Runtime? = nil
        if let runtimeRaw {
            runtime = CLISession.Metadata.Runtime(
                provider: runtimeRaw["provider"] as? String,
                agentVersion: runtimeRaw["agentVersion"] as? String,
                status: runtimeRaw["status"] as? String,
                statusDetail: runtimeRaw["statusDetail"] as? String,
                permissionMode: runtimeRaw["permissionMode"] as? String,
                permissionModeLabel: runtimeRaw["permissionModeLabel"] as? String,
                reasoningEffort: runtimeRaw["reasoningEffort"] as? String,
                reasoningEffortLabel: runtimeRaw["reasoningEffortLabel"] as? String,
                supportedReasoningEfforts: runtimeRaw["supportedReasoningEfforts"] as? [String],
                opencodeModeId: runtimeRaw["opencodeModeId"] as? String,
                opencodeModeLabel: runtimeRaw["opencodeModeLabel"] as? String,
                opencodeModelId: runtimeRaw["opencodeModelId"] as? String,
                opencodeVariant: runtimeRaw["opencodeVariant"] as? String,
                opencodeAvailableVariants: runtimeRaw["opencodeAvailableVariants"] as? [String],
                model: runtimeRaw["model"] as? String,
                contextSize: parseInt(runtimeRaw["contextSize"]),
                contextWindow: parseInt(runtimeRaw["contextWindow"]),
                contextRemainingPercent: parseDouble(runtimeRaw["contextRemainingPercent"]),
                mcpReady: runtimeRaw["mcpReady"] as? [String],
                mcpFailed: runtimeRaw["mcpFailed"] as? [String],
                mcpCancelled: runtimeRaw["mcpCancelled"] as? [String],
                mcpToolNames: runtimeRaw["mcpToolNames"] as? [String],
                mcpStartupPhase: runtimeRaw["mcpStartupPhase"] as? String,
                mcpStartupUpdatedAt: parseDate(runtimeRaw["mcpStartupUpdatedAt"]),
                skillAvailableCount: parseInt(runtimeRaw["skillAvailableCount"]),
                skillLoadedCount: parseInt(runtimeRaw["skillLoadedCount"]),
                skillLoadedUris: parseStringList(runtimeRaw["skillLoadedUris"] ?? runtimeRaw["loadedSkillUris"]),
                skillLoadState: runtimeRaw["skillLoadState"] as? String,
                skillLastSyncAt: parseDate(runtimeRaw["skillLastSyncAt"]),
                skillLastError: runtimeRaw["skillLastError"] as? String,
                skills: parseRuntimeSkills(runtimeRaw["skills"]),
                updatedAt: parseDate(runtimeRaw["updatedAt"]),
                titleStatus: runtimeRaw["titleStatus"] as? String,
                titleSource: runtimeRaw["titleSource"] as? String,
                titleUpdatedAt: parseDate(runtimeRaw["titleUpdatedAt"]),
                titleLastError: runtimeRaw["titleLastError"] as? String
            )
        }

        return CLISession.Metadata(
            path: path,
            host: host,
            machineId: machineId,
            hostPid: hostPid,
            flavor: flavor,
            homeDir: homeDir,
            version: version,
            platform: platform,
            runtime: runtime,
            claudeSessionId: claudeSessionId,
            codexSessionId: codexSessionId,
            opencodeSessionId: opencodeSessionId,
            geminiSessionId: geminiSessionId,
            customTitle: customTitle,
            summary: summary,
            gitStatus: gitStatus
        )
    }

    private func parseInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let numberValue = value as? NSNumber { return numberValue.intValue }
        if let stringValue = value as? String { return Int(stringValue) }
        return nil
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double { return doubleValue }
        if let numberValue = value as? NSNumber { return numberValue.doubleValue }
        if let stringValue = value as? String { return Double(stringValue) }
        return nil
    }

    private func parseStringList(_ value: Any?) -> [String] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            guard let text = item as? String else { return nil }
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private func parseDictionary(_ value: Any?) -> [String: Any]? {
        if let dict = value as? [String: Any] {
            return dict
        }
        if let bridged = value as? [AnyHashable: Any] {
            return Dictionary(uniqueKeysWithValues: bridged.compactMap { entry in
                guard let key = entry.key as? String else { return nil }
                return (key, entry.value)
            })
        }
        return nil
    }

    private func parseSkillString(_ value: Any?) -> String? {
        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        if let dict = parseDictionary(value) {
            return firstNonEmptySkillString([
                dict["text"],
                dict["value"],
                dict["name"],
                dict["title"],
                dict["description"],
                dict["summary"]
            ])
        }
        return nil
    }

    private func firstNonEmptySkillString(_ values: [Any?]) -> String? {
        for value in values {
            if let normalized = parseSkillString(value) {
                return normalized
            }
        }
        return nil
    }

    private func parseSkillBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) { return true }
            if ["false", "0", "no", "n"].contains(normalized) { return false }
        }
        return nil
    }

    private func parseRuntimeSkill(_ value: Any?) -> CLISession.Metadata.Runtime.Skill? {
        guard let dict = value as? [String: Any] else { return nil }
        let nested = parseDictionary(dict["skill"])
            ?? parseDictionary(dict["metadata"])
            ?? parseDictionary(dict["data"])
        let skillUri = firstNonEmptySkillString([
            dict["skillUri"],
            dict["skillURI"],
            dict["skill_uri"],
            dict["uri"],
            nested?["skillUri"],
            nested?["skillURI"],
            nested?["skill_uri"],
            nested?["uri"]
        ])
        guard let skillUri, !skillUri.isEmpty else { return nil }

        let name = firstNonEmptySkillString([
            dict["name"],
            dict["displayName"],
            dict["skillName"],
            dict["title"],
            nested?["name"],
            nested?["displayName"],
            nested?["skillName"],
            nested?["title"]
        ])
        let description = firstNonEmptySkillString([
            dict["description"],
            dict["desc"],
            dict["summary"],
            dict["detail"],
            dict["promptTemplate"],
            nested?["description"],
            nested?["desc"],
            nested?["summary"],
            nested?["detail"],
            nested?["promptTemplate"]
        ])
        let scope = firstNonEmptySkillString([
            dict["scope"],
            nested?["scope"]
        ])
        let type = firstNonEmptySkillString([
            dict["type"],
            nested?["type"]
        ])
        let spaceId = firstNonEmptySkillString([
            dict["spaceId"],
            dict["spaceID"],
            nested?["spaceId"],
            nested?["spaceID"]
        ])

        return CLISession.Metadata.Runtime.Skill(
            skillUri: skillUri,
            name: (name?.isEmpty == false) ? name : nil,
            description: (description?.isEmpty == false) ? description : nil,
            scope: (scope?.isEmpty == false) ? scope : nil,
            type: (type?.isEmpty == false) ? type : nil,
            spaceId: (spaceId?.isEmpty == false) ? spaceId : nil,
            isSystem: parseSkillBool(dict["isSystem"]) ?? parseSkillBool(nested?["isSystem"]),
            isLoaded: dict["isLoaded"] as? Bool,
            lastLoadedAt: parseDate(dict["lastLoadedAt"])
        )
    }

    private func parseRuntimeSkills(_ value: Any?) -> [CLISession.Metadata.Runtime.Skill]? {
        guard let items = value as? [Any] else { return nil }
        let parsed = items.compactMap(parseRuntimeSkill)
        return parsed.isEmpty ? nil : parsed
    }

    private func parseJSONObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let interval = value as? TimeInterval {
            return interval > 1_000_000_000_000 ? Date(timeIntervalSince1970: interval / 1000.0) : Date(timeIntervalSince1970: interval)
        }
        if let intValue = value as? Int {
            let interval = TimeInterval(intValue)
            return interval > 1_000_000_000_000 ? Date(timeIntervalSince1970: interval / 1000.0) : Date(timeIntervalSince1970: interval)
        }
        if let string = value as? String {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: string) { return date }
            if let seconds = TimeInterval(string) {
                return seconds > 1_000_000_000_000 ? Date(timeIntervalSince1970: seconds / 1000.0) : Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }

    private func updateSessions(_ sessions: [CLISession]) {
        // Split strictly by remote `active` state:
        // active sessions stay on top, inactive sessions stay in historical.
        activeSessions = sessions.filter { $0.active }
        historicalSessions = sessions.filter { !$0.active }

        // Sort by updated time
        activeSessions.sort { $0.updatedAt > $1.updatedAt }
        historicalSessions.sort { $0.updatedAt > $1.updatedAt }
    }

    // MARK: - Actions

    func connect() {
        client.connect()
        Task {
            await syncRemoteSessions()
        }
    }

    func refresh() async {
        await loadSessionsFromDatabase()
        await syncRemoteSessions()
    }

    func deleteInactiveSession(_ session: CLISession) async {
        guard !session.active else { return }

        do {
            do {
                _ = try await client.deleteSession(sessionId: session.id)
            } catch {
                // If remote already removed, continue and clean local copy.
                if !isSessionMissingError(error) {
                    throw error
                }
            }

            let localSessions = try await sessionRepository.getAllSessionsIncludingArchived(agentId: agent.id)
            let targets = localSessions.filter { local in
                local.id == session.id || local.cliSessionId == session.id
            }

            for target in targets {
                try await sessionRepository.deleteSession(id: target.id, notifyCloud: false)
            }

            NotificationCenter.default.post(
                name: NSNotification.Name("CLISessionDeleted"),
                object: nil,
                userInfo: ["sessionId": session.id, "botId": agent.id]
            )

            await loadSessionsFromDatabase()
        } catch {
            print("[SessionListViewModel] ❌ Failed to delete inactive session \(session.id): \(error)")
            errorMessage = "删除会话失败: \(error.localizedDescription)"
            showError = true
        }
    }

    func archiveActiveSession(_ session: CLISession) async {
        guard session.active else { return }

        do {
            let localSessions = try await sessionRepository.getAllSessionsIncludingArchived(agentId: agent.id)
            let targets = localSessions.filter { local in
                local.id == session.id || local.cliSessionId == session.id
            }

            for target in targets {
                var archived = target
                archived.markRemoteDeleted(provider: "cli")
                try await sessionRepository.updateSession(archived, notifyCloud: false)
            }

            let result = await client.killSession(sessionId: session.id)
            if !result.success {
                print("[SessionListViewModel] ⚠️ archive remote step failed for \(session.id): \(result.message)")
            }

            NotificationCenter.default.post(
                name: NSNotification.Name("CLISessionDeleted"),
                object: nil,
                userInfo: ["sessionId": session.id, "botId": agent.id]
            )

            await loadSessionsFromDatabase()
        } catch {
            print("[SessionListViewModel] ❌ Failed to archive active session \(session.id): \(error)")
            errorMessage = "归档会话失败: \(error.localizedDescription)"
            showError = true
        }
    }

    private func isSessionMissingError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        if message.contains("session not found") {
            return true
        }
        if message.contains("not owned by user") {
            return true
        }
        return false
    }

    private func syncRemoteSessions() async {
        guard !isSyncingRemote else { return }
        isSyncingRemote = true
        defer { isSyncingRemote = false }

        do {
            _ = try await client.syncSessionsToLocal(agentId: agent.id, repository: sessionRepository)
            await loadSessionsFromDatabase()
            lastRemoteSyncAt = Date()
        } catch {
            print("[SessionListViewModel] ❌ Remote session sync failed: \(error)")
            errorMessage = "同步远端会话失败"
            showError = true
        }
    }
}
