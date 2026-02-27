//
//  CLISessionSettings.swift
//  contextgo
//
//  Read-only runtime/session diagnostics
//

import SwiftUI

struct RuntimeRawModeOption: Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
}

struct CLISessionSettings: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedTab: SettingsTab = .tools
    @State private var expandedSkillDescriptions: Set<String> = []

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case tools
        case skills

        var id: String { rawValue }

        var title: String {
            switch self {
            case .tools:
                return "Tools"
            case .skills:
                return "Skills"
            }
        }
    }

    let runtimeMode: RuntimePermissionMode
    let runtimeModeOptions: [RuntimePermissionMode]
    let isRuntimeModeUpdating: Bool
    let runtimeModeUpdateError: String?
    let onUpdateRuntimeMode: ((RuntimePermissionMode) -> Void)?
    let runtimeControlMode: RuntimeControlMode
    let runtimeModel: String?
    let mcpReady: [String]
    let mcpFailed: [String]
    let mcpCancelled: [String]
    let mcpToolNames: [String]
    let mcpStartupPhase: String?
    let mcpStartupUpdatedAt: Date?
    let skillAvailableCount: Int
    let skillLoadedCount: Int
    let loadedSkillUris: [String]
    let skillLoadState: String?
    let skillLastSyncAt: Date?
    let skillLastError: String?
    let skills: [CLISession.Metadata.Runtime.Skill]
    let isSkillsRefreshing: Bool
    let skillActionError: String?
    let onRefreshSkills: (() -> Void)?
    let isReplayRefreshing: Bool
    let replayRefreshError: String?
    let onReplayRefresh: (() -> Void)?
    let preferCodexPermissionNaming: Bool
    let preferSkillsTab: Bool
    let rawRuntimeModeId: String?
    let rawRuntimeModeOptions: [RuntimeRawModeOption]
    let isRawRuntimeModeUpdating: Bool
    let onUpdateRawRuntimeMode: ((String) -> Void)?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("接管模式")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(runtimeControlMode.detailText)
                            .foregroundColor(runtimeControlMode.tintColor)
                            .font(.system(size: 14, weight: .medium))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("运行")
                                .foregroundColor(.secondary)
                            Spacer()
                            if isRuntimeModeUpdating || isRawRuntimeModeUpdating {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        if !rawRuntimeModeOptions.isEmpty {
                            ForEach(rawRuntimeModeOptions) { mode in
                                Button {
                                    onUpdateRawRuntimeMode?(mode.id)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: mode.id == rawRuntimeModeId ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(mode.id == rawRuntimeModeId ? .teal : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(mode.name)
                                                .foregroundColor(.primary)
                                                .font(.system(size: 14, weight: mode.id == rawRuntimeModeId ? .semibold : .regular))
                                            if let description = mode.description,
                                               !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                                Text(description)
                                                    .foregroundColor(.secondary)
                                                    .font(.system(size: 12))
                                                    .lineLimit(2)
                                            }
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isRawRuntimeModeUpdating || mode.id == rawRuntimeModeId)
                            }
                        } else {
                            ForEach(runtimeModeOptions, id: \.rawValue) { mode in
                                Button {
                                    onUpdateRuntimeMode?(mode)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: mode == runtimeMode ? "checkmark.circle.fill" : "circle")
                                            .foregroundColor(mode == runtimeMode ? mode.tintColor : .secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(mode.displayName(preferCodexPermissionNaming: preferCodexPermissionNaming))
                                                .foregroundColor(.primary)
                                                .font(.system(size: 14, weight: mode == runtimeMode ? .semibold : .regular))
                                            Text(mode.description(preferCodexPermissionNaming: preferCodexPermissionNaming))
                                                .foregroundColor(.secondary)
                                                .font(.system(size: 12))
                                                .lineLimit(2)
                                        }
                                        Spacer()
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(isRuntimeModeUpdating || mode == runtimeMode)
                            }
                        }

                        if let runtimeModeUpdateError,
                           !runtimeModeUpdateError.isEmpty {
                            Text(runtimeModeUpdateError)
                                .font(.system(size: 12))
                                .foregroundColor(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    HStack {
                        Text("当前模型")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(runtimeModel ?? "unknown")
                            .foregroundColor(.blue)
                            .font(.system(size: 14, weight: .medium))
                    }
                } header: {
                    Label("当前配置", systemImage: "info.circle")
                } footer: {
                    Text("接管模式（Local/Remote）由 CLI 与消息来源自动决定；仅运行模式支持在此修改。")
                        .font(.caption)
                }

                Section {
                    Picker("类型", selection: $selectedTab) {
                        ForEach(SettingsTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if selectedTab == .tools {
                    toolsSection
                } else {
                    skillsSection
                }

                Section {
                    Button {
                        onReplayRefresh?()
                    } label: {
                        HStack(spacing: 10) {
                            if isReplayRefreshing {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "arrow.clockwise.circle")
                                    .foregroundColor(.orange)
                            }
                            Text(isReplayRefreshing ? "正在清空并重新拉取…" : "清空本地并重新回放")
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }
                    .disabled(isReplayRefreshing)

                    if let replayRefreshError,
                       !replayRefreshError.isEmpty {
                        Text(replayRefreshError)
                            .font(.system(size: 12))
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Label("调试操作（可下线）", systemImage: "ladybug")
                } footer: {
                    Text("仅清理当前会话的本地缓存，然后从服务端按 seq 重新拉取。不会删除服务端会话。")
                        .font(.caption)
                }
            }
            .navigationTitle("会话设置")
            .onAppear {
                selectedTab = preferSkillsTab ? .skills : .tools
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var toolsSection: some View {
        Section {
            if mcpReady.isEmpty, mcpFailed.isEmpty, mcpCancelled.isEmpty {
                Text("暂无 MCP 启动结果")
                    .foregroundColor(.secondary)
            } else {
                HStack {
                    Text("Ready")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(mcpReady.isEmpty ? "无" : mcpReady.joined(separator: ", "))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.green)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("Failed")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(mcpFailed.isEmpty ? "无" : mcpFailed.joined(separator: ", "))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(mcpFailed.isEmpty ? .secondary : .red)
                        .multilineTextAlignment(.trailing)
                }

                HStack {
                    Text("Cancelled")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(mcpCancelled.isEmpty ? "无" : mcpCancelled.joined(separator: ", "))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(mcpCancelled.isEmpty ? .secondary : .orange)
                        .multilineTextAlignment(.trailing)
                }
            }

            HStack {
                Text("阶段")
                    .foregroundColor(.secondary)
                Spacer()
                Text(mcpStartupPhase ?? "unknown")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("MCP Tools")
                    .foregroundColor(.secondary)
                Spacer()
                Text(mcpToolNames.isEmpty ? "无" : mcpToolNames.joined(separator: ", "))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(mcpToolNames.isEmpty ? .secondary : .blue)
                    .multilineTextAlignment(.trailing)
            }

            if let updatedAt = mcpStartupUpdatedAt {
                HStack {
                    Text("更新时间")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(updatedAt.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Label("MCP 启动状态", systemImage: "externaldrive.connected.to.line.below")
        } footer: {
            Text("该信息来自 MCP runtime metadata。")
                .font(.caption)
        }
    }

    @ViewBuilder
    private var skillsSection: some View {
        Section {
            HStack {
                Text("可用技能")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(skillAvailableCount)")
                    .font(.system(size: 13, weight: .medium))
            }

            HStack {
                Text("已读取技能")
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(skillLoadedCount)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(skillLoadedCount > 0 ? .green : .secondary)
            }

            HStack {
                Text("加载状态")
                    .foregroundColor(.secondary)
                Spacer()
                Text(skillLoadState ?? "idle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
            }

            if let lastSyncAt = skillLastSyncAt {
                HStack {
                    Text("同步时间")
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(lastSyncAt.formatted(date: .omitted, time: .standard))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            Button {
                onRefreshSkills?()
            } label: {
                HStack(spacing: 10) {
                    if isSkillsRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .foregroundColor(.blue)
                    }
                    Text(isSkillsRefreshing ? "刷新中…" : "刷新技能列表")
                        .foregroundColor(.primary)
                    Spacer()
                }
            }
            .disabled(isSkillsRefreshing)

            if let skillLastError, !skillLastError.isEmpty {
                Text(skillLastError)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let skillActionError, !skillActionError.isEmpty {
                Text(skillActionError)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Label("技能状态", systemImage: "bolt.horizontal.circle")
        }

        Section {
            if skills.isEmpty {
                Text("暂无可用技能，点击“刷新技能列表”后重试。")
                    .foregroundColor(.secondary)
            } else {
                ForEach(skills, id: \.skillUri) { skill in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Text(skill.name ?? skill.skillUri)
                                .font(.system(size: 14, weight: .semibold))
                                .lineLimit(1)
                            if isSystemSkill(skill) {
                                Text("系统")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.14))
                                    .clipShape(Capsule())
                            }
                            Spacer()
                            if isSkillLoaded(skill) {
                                Text("已读")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.green)
                            }
                        }

                        if let description = skill.description,
                           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Button {
                                toggleSkillDescription(skill.skillUri)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(description)
                                        .font(.system(size: 12, weight: .regular))
                                        .foregroundColor(.secondary)
                                        .lineLimit(isSkillDescriptionExpanded(skill.skillUri) ? nil : 2)
                                    Text(isSkillDescriptionExpanded(skill.skillUri) ? "收起描述" : "展开描述")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.blue)
                                }
                            }
                            .buttonStyle(.plain)
                        }

                        Text(skill.skillUri)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Label("可用技能", systemImage: "list.bullet.rectangle")
        } footer: {
            Text("“已读取”表示模型在当前会话中实际调用过 skill_get。")
                .font(.caption)
        }
    }

    private func isSkillLoaded(_ skill: CLISession.Metadata.Runtime.Skill) -> Bool {
        if let isLoaded = skill.isLoaded {
            return isLoaded
        }
        return loadedSkillUris.contains(skill.skillUri)
    }

    private func isSystemSkill(_ skill: CLISession.Metadata.Runtime.Skill) -> Bool {
        if let explicit = skill.isSystem {
            return explicit
        }
        return skill.skillUri.lowercased().hasSuffix("/skill_creator")
    }

    private func isSkillDescriptionExpanded(_ skillUri: String) -> Bool {
        expandedSkillDescriptions.contains(skillUri)
    }

    private func toggleSkillDescription(_ skillUri: String) {
        if expandedSkillDescriptions.contains(skillUri) {
            expandedSkillDescriptions.remove(skillUri)
        } else {
            expandedSkillDescriptions.insert(skillUri)
        }
    }
}

enum RuntimePermissionMode: String, Codable, CaseIterable {
    case readOnly = "read-only"
    case defaultMode = "default"
    case fullAccess = "full-access"
    case safeYolo = "safe-yolo"
    case yolo
    case acceptEdits = "acceptEdits"
    case plan
    case dontAsk = "dontAsk"
    case bypassPermissions = "bypassPermissions"

    func displayName(preferCodexPermissionNaming: Bool = false) -> String {
        switch self {
        case .readOnly: return "read-only"
        case .defaultMode: return preferCodexPermissionNaming ? "workspace-write" : "default"
        case .fullAccess: return preferCodexPermissionNaming ? "danger-full-access" : "full-access"
        case .safeYolo: return "safe-yolo"
        case .yolo: return "yolo"
        case .acceptEdits: return "acceptEdits"
        case .plan: return "plan"
        case .dontAsk: return "dontAsk"
        case .bypassPermissions: return "bypassPermissions"
        }
    }

    var displayName: String {
        displayName(preferCodexPermissionNaming: false)
    }

    var detailText: String {
        switch self {
        case .readOnly: return "read-only (Codex)"
        case .defaultMode: return "default (Claude)"
        case .fullAccess: return "danger-full-access (Codex)"
        case .safeYolo: return "safe-yolo (Legacy)"
        case .yolo: return "yolo (Legacy)"
        case .acceptEdits: return "acceptEdits"
        case .plan: return "plan"
        case .dontAsk: return "dontAsk"
        case .bypassPermissions: return "bypassPermissions"
        }
    }

    func description(preferCodexPermissionNaming: Bool = false) -> String {
        switch self {
        case .readOnly:
            return "Codex 原生模式 read-only：工作区只读，写入与高风险能力受限。"
        case .defaultMode:
            if preferCodexPermissionNaming {
                return "Codex 原生模式 workspace-write：可读写工作区；高风险操作需确认。"
            }
            return "Standard behavior, prompts for dangerous operations."
        case .fullAccess:
            if preferCodexPermissionNaming {
                return "Codex 原生模式 danger-full-access：全权限执行，请谨慎使用。"
            }
            return "Full access mode."
        case .safeYolo:
            return "Legacy 模式名 safe-yolo（兼容旧链路）。"
        case .yolo:
            return "Legacy 模式名 yolo（兼容旧链路）。"
        case .acceptEdits:
            return "Auto-accept file edit operations."
        case .plan:
            return "Planning mode, no actual tool execution."
        case .dontAsk:
            return "Don't prompt for permissions, deny if not pre-approved."
        case .bypassPermissions:
            return "Bypass all permission checks."
        }
    }

    var description: String {
        description(preferCodexPermissionNaming: false)
    }

    var usesLegacyYolo: Bool {
        self == .yolo || self == .fullAccess || self == .bypassPermissions
    }

    var isClaudeOnly: Bool {
        self == .defaultMode || self == .acceptEdits || self == .plan || self == .dontAsk || self == .bypassPermissions
    }

    var tintColor: Color {
        switch self {
        case .readOnly: return .indigo
        case .defaultMode: return .blue
        case .fullAccess: return .red
        case .safeYolo: return .blue
        case .yolo: return .orange
        case .acceptEdits: return .teal
        case .plan: return .indigo
        case .dontAsk: return .orange
        case .bypassPermissions: return .red
        }
    }

    static func fromRuntimePermission(
        _ runtimePermission: String?,
        supportsClaudeExtendedModes: Bool,
        preferCodexPermissionNaming: Bool = false
    ) -> RuntimePermissionMode {
        switch runtimePermission?.lowercased() {
        case "read-only", "readonly":
            return .readOnly
        case "workspace-write":
            return .defaultMode
        case "danger-full-access":
            return .fullAccess
        case "default":
            return .defaultMode
        case "full-access", "fullaccess":
            return .fullAccess
        case "safe-yolo":
            return preferCodexPermissionNaming ? .defaultMode : .safeYolo
        case "accept-edits", "acceptedits":
            return supportsClaudeExtendedModes ? .acceptEdits : (preferCodexPermissionNaming ? .defaultMode : .safeYolo)
        case "plan":
            return supportsClaudeExtendedModes ? .plan : (preferCodexPermissionNaming ? .defaultMode : .safeYolo)
        case "dontask", "dont-ask":
            return supportsClaudeExtendedModes ? .dontAsk : (preferCodexPermissionNaming ? .defaultMode : .safeYolo)
        case "bypasspermissions", "bypass-permissions":
            return supportsClaudeExtendedModes ? .bypassPermissions : (preferCodexPermissionNaming ? .fullAccess : .yolo)
        case "yolo":
            if preferCodexPermissionNaming {
                return .fullAccess
            }
            return supportsClaudeExtendedModes ? .bypassPermissions : .yolo
        default:
            if preferCodexPermissionNaming {
                return .defaultMode
            }
            return supportsClaudeExtendedModes ? .defaultMode : .safeYolo
        }
    }

    static func fromRuntimePermissionList(
        _ values: [String]?,
        supportsClaudeExtendedModes: Bool,
        preferCodexPermissionNaming: Bool = false
    ) -> [RuntimePermissionMode] {
        guard let values else { return [] }
        var seen = Set<RuntimePermissionMode>()
        var ordered: [RuntimePermissionMode] = []

        for value in values {
            let mapped = fromRuntimePermission(
                value,
                supportsClaudeExtendedModes: supportsClaudeExtendedModes,
                preferCodexPermissionNaming: preferCodexPermissionNaming
            )
            if seen.insert(mapped).inserted {
                ordered.append(mapped)
            }
        }

        return ordered
    }
}

enum RuntimeControlMode: String, Codable, CaseIterable {
    case local
    case remote

    var displayName: String {
        switch self {
        case .local: return "Local"
        case .remote: return "Remote"
        }
    }

    var detailText: String {
        switch self {
        case .local: return "Local（电脑接管）"
        case .remote: return "Remote（手机接管）"
        }
    }

    var description: String {
        switch self {
        case .local:
            return "当前由电脑端主导运行；手机端发消息会触发切回 Remote。"
        case .remote:
            return "当前由手机端主导运行，可远程下发消息和控制。"
        }
    }

    var tintColor: Color {
        switch self {
        case .local: return .indigo
        case .remote: return .blue
        }
    }

    static func fromRuntimeMode(_ runtimeMode: String?) -> RuntimeControlMode {
        switch runtimeMode?.lowercased() {
        case "local":
            return .local
        case "remote":
            return .remote
        default:
            return .remote
        }
    }
}

// MARK: - Preview

#Preview {
    CLISessionSettings(
        runtimeMode: .safeYolo,
        runtimeModeOptions: [.safeYolo, .yolo],
        isRuntimeModeUpdating: false,
        runtimeModeUpdateError: nil,
        onUpdateRuntimeMode: nil,
        runtimeControlMode: .remote,
        runtimeModel: "claude-sonnet-4",
        mcpReady: ["cgo"],
        mcpFailed: [],
        mcpCancelled: [],
        mcpToolNames: ["change_title", "context_read", "context_write", "search_context", "skill_list", "skill_get", "skill_create", "skill_delete"],
        mcpStartupPhase: "complete",
        mcpStartupUpdatedAt: Date(),
        skillAvailableCount: 3,
        skillLoadedCount: 1,
        loadedSkillUris: ["ctxgo://preview-user/skills/rd-intake-design-gate"],
        skillLoadState: "ready",
        skillLastSyncAt: Date(),
        skillLastError: nil,
        skills: [
            .init(
                skillUri: "ctxgo://preview-user/skills/rd-intake-design-gate",
                name: "rd-intake-design-gate",
                description: "需求澄清与设计评审门禁，确保开发前输入完整。",
                scope: "user",
                type: "custom",
                spaceId: nil,
                isSystem: false,
                isLoaded: true,
                lastLoadedAt: Date()
            ),
            .init(
                skillUri: "ctxgo://preview-user/skills/rd-implementation-pr-ledger",
                name: "rd-implementation-pr-ledger",
                description: "实现-提测-提PR全流程台账与状态追踪。",
                scope: "user",
                type: "custom",
                spaceId: nil,
                isSystem: false,
                isLoaded: false,
                lastLoadedAt: nil
            )
        ],
        isSkillsRefreshing: false,
        skillActionError: nil,
        onRefreshSkills: nil,
        isReplayRefreshing: false,
        replayRefreshError: nil,
        onReplayRefresh: nil,
        preferCodexPermissionNaming: false,
        preferSkillsTab: false,
        rawRuntimeModeId: nil,
        rawRuntimeModeOptions: [],
        isRawRuntimeModeUpdating: false,
        onUpdateRawRuntimeMode: nil
    )
}
