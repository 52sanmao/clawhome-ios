//
//  SessionInfoView.swift
//  contextgo
//
//  Session information and quick actions
//

import SwiftUI
import UIKit

struct SessionInfoView: View {
    let session: CLISession
    let client: RelayClient?
    var onSessionArchived: (() -> Void)? = nil
    var onSessionDeleted: (() -> Void)? = nil

    @State private var showCopyToast = false
    @State private var copiedText = ""

    @State private var showArchiveConfirm = false
    @State private var showDeleteConfirm = false
    @State private var actionErrorMessage: String?
    @State private var showActionError = false
    @State private var isProcessingAction = false
    @State private var isSessionArchived = false
    @State private var daemonPid: Int?
    @State private var daemonStatus: String?
    @State private var isLoadingDaemonInfo = false
    @State private var isLoadingOpenCodePluginInfo = false
    @State private var openCodePluginInfo: OpenCodePluginInfo?

    private let sessionRepository = LocalSessionRepository.shared

    var body: some View {
        let flavor = session.metadata?.flavor?.lowercased()
        let linkedSessionLabel: String? = {
            switch flavor {
            case "codex": return "Codex Resume Session ID"
            case "opencode": return "OpenCode Session ID"
            case "gemini": return "Gemini Session ID"
            default: return nil
            }
        }()
        let linkedSessionId: String? = {
            switch flavor {
            case "codex": return session.metadata?.codexSessionId
            case "opencode": return session.metadata?.opencodeSessionId
            case "gemini": return session.metadata?.geminiSessionId
            default: return nil
            }
        }()

        List {
            Section {
                Button {
                    copyToClipboard(session.id, label: "ContextGo Session ID")
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ContextGo Session ID")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(.primary)

                            Text(formatSessionId(session.id))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Image(systemName: "doc.on.doc")
                            .foregroundColor(.blue)
                    }
                }
                .buttonStyle(.plain)

                if let claudeSessionId = session.metadata?.claudeSessionId {
                    Button {
                        copyToClipboard(claudeSessionId, label: "Claude Code Session ID")
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Claude Code Session ID")
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.primary)

                                Text(formatSessionId(claudeSessionId))
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.purple)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if let linkedSessionLabel, let linkedSessionId {
                    Button {
                        copyToClipboard(linkedSessionId, label: linkedSessionLabel)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(linkedSessionLabel)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(.primary)

                                Text(formatSessionId(linkedSessionId))
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.blue)
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Session IDs")
            } footer: {
                Text("点击复制完整 ID")
            }

            Section("状态") {
                HStack {
                    Text("状态")
                    Spacer()
                    SessionStatusView(status: session.sessionStatus)
                }

                HStack {
                    Text("在线")
                    Spacer()
                    Text(session.presence.isOnline ? "是" : "否")
                        .foregroundColor(.secondary)
                }

                if !session.presence.isOnline, let lastSeen = session.presence.lastSeenText {
                    HStack {
                        Text("最后在线")
                        Spacer()
                        Text(lastSeen)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let metadata = session.metadata {
                Section("元数据") {
                    LabeledContent("主机", value: metadata.host)
                    LabeledContent("路径", value: metadata.displayPath)
                    LabeledContent("CLI 版本", value: metadata.version)
                    LabeledContent(
                        "AI 提供商 CLI 版本",
                        value: metadata.runtime?.agentVersion ?? metadata.version
                    )
                    HStack(spacing: 12) {
                        Text("机器 ID")

                        Spacer()

                        Text(metadata.machineId)
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 190, alignment: .trailing)

                        Button {
                            copyToClipboard(metadata.machineId, label: "机器 ID")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    LabeledContent("Home", value: metadata.homeDir)

                    if let platform = metadata.platform {
                        LabeledContent("平台", value: platform)
                    }

                    if let provider = metadata.runtime?.provider ?? metadata.flavor {
                        LabeledContent("AI 提供商", value: provider.capitalized)
                    }

                    if let titleStatus = metadata.runtime?.titleStatus {
                        LabeledContent("标题同步", value: formatTitleSyncStatus(titleStatus))
                    }

                    if let titleSource = metadata.runtime?.titleSource {
                        LabeledContent("标题来源", value: titleSource.uppercased())
                    }

                    if let titleUpdatedAt = metadata.runtime?.titleUpdatedAt {
                        LabeledContent("标题更新时间", value: formatDate(titleUpdatedAt))
                    }

                    if let titleLastError = metadata.runtime?.titleLastError, !titleLastError.isEmpty {
                        LabeledContent("标题错误", value: titleLastError)
                    }
                }

                Section("进程") {
                    if let hostPid = metadata.hostPid {
                        LabeledContent("宿主进程 PID", value: "\(hostPid)")
                    } else {
                        LabeledContent("宿主进程 PID", value: "未知")
                    }

                    if isLoadingDaemonInfo {
                        LabeledContent("守护进程 PID", value: "加载中")
                    } else if let daemonPid {
                        LabeledContent("守护进程 PID", value: "\(daemonPid)")
                    } else {
                        LabeledContent("守护进程 PID", value: "未知")
                    }

                    if let daemonStatus, !daemonStatus.isEmpty {
                        LabeledContent("守护进程状态", value: daemonStatus)
                    }

                    if let upstream = metadata.gitStatus?.upstreamBranch, !upstream.isEmpty {
                        LabeledContent("Git Upstream", value: upstream)
                    }
                }
            }

            if let gitStatus = session.metadata?.gitStatus {
                Section("Git 状态") {
                    HStack {
                        Text("分支")
                        Spacer()
                        HStack(spacing: 4) {
                            Image(systemName: "branch")
                                .foregroundColor(.secondary)
                            Text(gitStatus.branch ?? "unknown")
                                .foregroundColor(.secondary)
                        }
                    }

                    HStack {
                        Text("状态")
                        Spacer()
                        HStack(spacing: 4) {
                            Circle()
                                .fill((gitStatus.isDirty ?? false) ? Color.orange : Color.green)
                                .frame(width: 8, height: 8)
                            Text((gitStatus.isDirty ?? false) ? "有未提交更改" : "干净")
                                .foregroundColor(.secondary)
                        }
                    }

                    if let files = gitStatus.changedFiles {
                        LabeledContent("变更文件数", value: "\(files)")
                    }

                    if let added = gitStatus.addedLines {
                        LabeledContent("新增行数", value: "+\(added)")
                    }

                    if let deleted = gitStatus.deletedLines {
                        LabeledContent("删除行数", value: "-\(deleted)")
                    }

                    if let ahead = gitStatus.aheadCount {
                        LabeledContent("领先提交", value: "\(ahead)")
                    }

                    if let behind = gitStatus.behindCount {
                        LabeledContent("落后提交", value: "\(behind)")
                    }
                }
            }

            Section("时间") {
                LabeledContent("创建时间", value: formatDate(session.createdAt))
                LabeledContent("更新时间", value: formatDate(session.updatedAt))
                LabeledContent("活跃时间", value: formatDate(session.activeAt))
            }

            Section("其他") {
                LabeledContent("序列号", value: "\(session.seq)")
                LabeledContent("Agent 状态版本", value: "\(session.agentStateVersion)")
            }

            if isOpenCodeSession {
                openCodePluginSection
            }

            Section("操作") {
                if isSessionArchived {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            if isProcessingAction {
                                ProgressView()
                            }
                            Text("删除会话")
                        }
                    }
                    .disabled(isProcessingAction)
                } else {
                    Button(role: .destructive) {
                        showArchiveConfirm = true
                    } label: {
                        HStack {
                            if isProcessingAction {
                                ProgressView()
                            }
                            Text("归档会话")
                        }
                    }
                    .disabled(isProcessingAction)
                }
            }
        }
        .navigationTitle("会话信息")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: session.metadata?.machineId ?? "") {
            await refreshArchiveState()
            await loadDaemonProcessInfo()
            await loadOpenCodePluginInfo()
        }
        .overlay(alignment: .top) {
            if showCopyToast {
                ToastView(message: "已复制 \(copiedText)")
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .alert("归档会话", isPresented: $showArchiveConfirm) {
            Button("取消", role: .cancel) { }
            Button("归档", role: .destructive) {
                Task {
                    await archiveSession()
                }
            }
        } message: {
            Text("归档后会话将停止通信，但仍保留在列表中可查看。")
        }
        .alert("删除会话", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) { }
            Button("删除", role: .destructive) {
                Task {
                    await deleteSession()
                }
            }
        } message: {
            Text("删除后无法恢复。")
        }
        .alert("操作失败", isPresented: $showActionError) {
            Button("确定", role: .cancel) { }
        } message: {
            Text(actionErrorMessage ?? "未知错误")
        }
    }

    // MARK: - Helper Methods

    private func formatSessionId(_ id: String) -> String {
        let prefix = String(id.prefix(8))
        let suffix = String(id.suffix(8))
        return "\(prefix)...\(suffix)"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func formatTitleSyncStatus(_ status: String) -> String {
        switch status.lowercased() {
        case "synced":
            return "已同步"
        case "pending":
            return "待同步"
        case "failed":
            return "同步失败"
        default:
            return status
        }
    }

    private func copyToClipboard(_ text: String, label: String) {
        UIPasteboard.general.string = text
        copiedText = label

        withAnimation(.spring(response: 0.3)) {
            showCopyToast = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.3)) {
                showCopyToast = false
            }
        }
    }

    private func archiveSession() async {
        guard !isProcessingAction else { return }
        isProcessingAction = true
        defer { isProcessingAction = false }

        do {
            if var local = try await sessionRepository.getSession(id: session.id) {
                local.markRemoteDeleted(provider: "cli")
                try await sessionRepository.updateSession(local, notifyCloud: false)
            }
            isSessionArchived = true

            if let client {
                NotificationCenter.default.post(
                    name: NSNotification.Name("CLISessionDeleted"),
                    object: nil,
                    userInfo: ["sessionId": session.id, "botId": client.ownerAgentId]
                )
            } else {
                NotificationCenter.default.post(
                    name: NSNotification.Name("CLISessionDeleted"),
                    object: nil,
                    userInfo: ["sessionId": session.id]
                )
            }

            onSessionArchived?()

            if let client {
                let result = await client.killSession(sessionId: session.id)
                guard result.success else {
                    print("⚠️ [SessionInfoView] archive remote step failed: \(result.message)")
                    return
                }
            }
        } catch {
            actionErrorMessage = error.localizedDescription
            showActionError = true
        }
    }

    private func deleteSession() async {
        guard !isProcessingAction else { return }
        isProcessingAction = true
        defer { isProcessingAction = false }

        guard isSessionArchived else {
            actionErrorMessage = "请先归档会话，再执行删除"
            showActionError = true
            return
        }

        do {
            if let client {
                do {
                    _ = try await client.deleteSession(sessionId: session.id)
                } catch {
                    let message = error.localizedDescription.lowercased()
                    // Remote may have already been removed by a previous archive fallback path.
                    if !message.contains("session not found") && !message.contains("not owned by user") {
                        throw error
                    }
                }
                NotificationCenter.default.post(
                    name: NSNotification.Name("CLISessionDeleted"),
                    object: nil,
                    userInfo: ["sessionId": session.id, "botId": client.ownerAgentId]
                )
            }

            if let _ = try await sessionRepository.getSession(id: session.id) {
                try await sessionRepository.deleteSession(id: session.id, notifyCloud: false)
            }

            onSessionDeleted?()
        } catch {
            actionErrorMessage = error.localizedDescription
            showActionError = true
        }
    }

    private func refreshArchiveState() async {
        do {
            guard let local = try await sessionRepository.getSession(id: session.id) else {
                isSessionArchived = false
                return
            }
            let metadata = local.channelMetadataDict
            let remoteDeleted = (metadata?["remoteDeleted"] as? Bool) ?? false
            isSessionArchived = local.isArchived || remoteDeleted
        } catch {
            isSessionArchived = false
        }
    }

    private func loadDaemonProcessInfo() async {
        guard let client,
              let machineId = session.metadata?.machineId,
              !machineId.isEmpty else {
            daemonPid = nil
            daemonStatus = nil
            isLoadingDaemonInfo = false
            return
        }

        isLoadingDaemonInfo = true
        defer { isLoadingDaemonInfo = false }

        do {
            if let machine = try await client.fetchMachine(machineId: machineId) {
                daemonPid = machine.daemonPid
                daemonStatus = machine.daemonStatus
            } else {
                daemonPid = nil
                daemonStatus = nil
            }
        } catch {
            daemonPid = nil
            daemonStatus = nil
            print("⚠️ [SessionInfoView] failed to load daemon info: \(error)")
        }
    }

    private var isOpenCodeSession: Bool {
        session.metadata?.flavor?.lowercased() == "opencode"
            || session.metadata?.runtime?.provider?.lowercased() == "opencode"
    }

    @ViewBuilder
    private var openCodePluginSection: some View {
        Section {
            if isLoadingOpenCodePluginInfo {
                LabeledContent("检测状态", value: "加载中")
            } else if let info = openCodePluginInfo {
                LabeledContent("检测状态", value: info.detected ? "已检测" : "未检测")
                LabeledContent("注册状态", value: info.registered ? "已注册" : "未注册")

                if let entry = info.entry, !entry.isEmpty {
                    HStack(spacing: 12) {
                        Text("插件入口")
                        Spacer()
                        Text(entry)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                        Button {
                            copyToClipboard(entry, label: "oh-my-opencode 插件入口")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let configPath = info.configPath, !configPath.isEmpty {
                    HStack(spacing: 12) {
                        Text("OpenCode 配置")
                        Spacer()
                        Text(configPath)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                        Button {
                            copyToClipboard(configPath, label: "OpenCode 配置路径")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let userConfigPath = info.userConfigPath, !userConfigPath.isEmpty {
                    HStack(spacing: 12) {
                        Text("OMO 用户配置")
                        Spacer()
                        Text(userConfigPath)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                        Button {
                            copyToClipboard(userConfigPath, label: "OMO 用户配置路径")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let projectConfigPath = info.projectConfigPath, !projectConfigPath.isEmpty {
                    HStack(spacing: 12) {
                        Text("OMO 项目配置")
                        Spacer()
                        Text(projectConfigPath)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 220, alignment: .trailing)
                        Button {
                            copyToClipboard(projectConfigPath, label: "OMO 项目配置路径")
                        } label: {
                            Image(systemName: "doc.on.doc")
                                .foregroundColor(.blue)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if !info.modeHints.isEmpty {
                    LabeledContent("命中 Agent", value: info.modeHints.joined(separator: ", "))
                }
            } else {
                LabeledContent("检测状态", value: "未获取")
            }
        } header: {
            Text("OpenCode 插件")
        } footer: {
            Text("来自 getRuntimeConfig 的 OpenCode 运行时检测结果")
        }
    }

    private func parseBool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool {
            return value
        }
        if let value = raw as? NSNumber {
            return value.boolValue
        }
        if let value = raw as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) {
                return true
            }
            if ["false", "0", "no", "n"].contains(normalized) {
                return false
            }
        }
        return nil
    }

    private func parseStringArray(_ raw: Any?) -> [String] {
        guard let values = raw as? [Any] else { return [] }
        return values.compactMap { value in
            guard let text = value as? String else { return nil }
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private func loadOpenCodePluginInfo() async {
        guard isOpenCodeSession, let client else {
            openCodePluginInfo = nil
            isLoadingOpenCodePluginInfo = false
            return
        }

        isLoadingOpenCodePluginInfo = true
        defer { isLoadingOpenCodePluginInfo = false }

        do {
            let runtimeConfig = try await client.getRuntimeConfig(for: session.id)
            let info = OpenCodePluginInfo(
                detected: parseBool(runtimeConfig["opencodeOhMyOpencodeDetected"]),
                registered: parseBool(runtimeConfig["opencodeOhMyOpencodeRegistered"]),
                entry: (runtimeConfig["opencodeOhMyOpencodeEntry"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                configPath: (runtimeConfig["opencodeOhMyOpencodeConfigPath"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                userConfigPath: (runtimeConfig["opencodeOhMyOpencodeUserConfigPath"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                projectConfigPath: (runtimeConfig["opencodeOhMyOpencodeProjectConfigPath"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                modeHints: parseStringArray(runtimeConfig["opencodeOhMyOpencodeModeHints"])
            )
            openCodePluginInfo = info
        } catch {
            openCodePluginInfo = nil
        }
    }
}

private struct OpenCodePluginInfo {
    let detected: Bool
    let registered: Bool
    let entry: String?
    let configPath: String?
    let userConfigPath: String?
    let projectConfigPath: String?
    let modeHints: [String]

    init(
        detected: Bool?,
        registered: Bool?,
        entry: String?,
        configPath: String?,
        userConfigPath: String?,
        projectConfigPath: String?,
        modeHints: [String]
    ) {
        self.detected = detected ?? false
        self.registered = registered ?? false
        self.entry = entry
        self.configPath = configPath
        self.userConfigPath = userConfigPath
        self.projectConfigPath = projectConfigPath
        self.modeHints = modeHints
    }
}

// MARK: - Toast View

struct ToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text(message)
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        )
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SessionInfoView(session: .sample, client: nil)
    }
}
