import SwiftUI

struct CodexToolEventCard: View {
    let toolUse: CLIMessage.ToolUse
    var isActionLoading: Bool = false
    var onAllow: ((String) -> Void)? = nil
    var onAllowForSession: ((String) -> Void)? = nil
    var onDeny: ((String) -> Void)? = nil

    @State private var showDetailSheet = false

    private var semanticKind: CLIToolCardKind {
        CLIToolSemantics.classifyToolName(toolUse.name)
    }

    private var isSkillGetTool: Bool {
        ToolCardSemanticHelpers.isSkillGetToolName(toolUse.name)
    }

    private var isSkillListTool: Bool {
        ToolCardSemanticHelpers.isSkillListToolName(toolUse.name)
    }

    private var isSkillCreateTool: Bool {
        ToolCardSemanticHelpers.isSkillCreateToolName(toolUse.name)
    }

    private var isSkillDeleteTool: Bool {
        ToolCardSemanticHelpers.isSkillDeleteToolName(toolUse.name)
    }

    private var skillSnapshot: SkillGetCardSnapshot? {
        ToolCardSemanticHelpers.skillGetPreviewSnapshot(for: toolUse)
    }

    private var skillListSnapshot: SkillListCardSnapshot? {
        ToolCardSemanticHelpers.skillListPreviewSnapshot(for: toolUse)
    }

    private var skillCreateSnapshot: SkillCreateCardSnapshot? {
        ToolCardSemanticHelpers.skillCreatePreviewSnapshot(for: toolUse)
    }

    private var skillDeleteSnapshot: SkillDeleteCardSnapshot? {
        ToolCardSemanticHelpers.skillDeletePreviewSnapshot(for: toolUse)
    }

    private var displayName: String {
        if isSkillGetTool {
            return "加载技能"
        }
        if isSkillListTool {
            return "技能列表"
        }
        if isSkillCreateTool {
            return skillCreateSnapshot?.skillName ?? "技能创建"
        }
        if isSkillDeleteTool {
            return skillDeleteSnapshot?.skillName ?? "技能删除"
        }
        let fallback = toolUse.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch semanticKind {
        case .command:
            return CommandToolCardContentView.displayName(for: renderContext)
        case .parallelDispatch:
            return "Explored"
        case .read:
            return "文件读取"
        case .glob:
            return "文件搜索"
        case .fileEdit:
            return "文件编辑"
        case .titleChange:
            return "标题更新"
        default:
            return fallback.isEmpty ? "Tool" : fallback
        }
    }

    private var iconName: String {
        if isSkillGetTool {
            return "book.closed"
        }
        if isSkillListTool {
            return "list.bullet.rectangle"
        }
        if isSkillCreateTool {
            return "plus.circle"
        }
        if isSkillDeleteTool {
            return "trash"
        }
        switch semanticKind {
        case .command:
            return CommandToolCardContentView.iconName(for: renderContext)
        case .fileEdit:
            return "square.and.pencil"
        case .read:
            return "doc.text"
        case .glob, .webSearch:
            return "magnifyingglass"
        case .todo:
            return "checklist"
        case .task, .backgroundTask:
            return "list.bullet.rectangle"
        case .parallelDispatch:
            return "square.stack.3d.down.right"
        case .sessionControl, .titleChange:
            return "slider.horizontal.3"
        case .reasoning:
            return "brain.head.profile"
        case .protocolFallback, .generic:
            return "tray.full"
        }
    }

    private var previewText: String {
        if isSkillGetTool {
            if let summary = skillSnapshot?.descriptionPreview,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return summary
            }
            if let uri = skillSnapshot?.skillUri,
               !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return uri
            }
            return "技能详情已返回"
        }
        if isSkillListTool {
            if let snapshot = skillListSnapshot, snapshot.totalCount > 0 {
                return "共 \(snapshot.totalCount) 个技能"
            }
            return "已返回技能列表"
        }
        if isSkillCreateTool {
            if let name = skillCreateSnapshot?.skillName, !name.isEmpty {
                return (skillCreateSnapshot?.overwritten == true ? "已覆盖更新: " : "已创建: ") + name
            }
            return "已执行技能创建"
        }
        if isSkillDeleteTool {
            if let name = skillDeleteSnapshot?.skillName, !name.isEmpty {
                return "已删除: \(name)"
            }
            return "已执行技能删除"
        }

        switch semanticKind {
        case .command:
            return codexCommandSummary()
        case .titleChange:
            if let changedTitle = changedTitlePreview() {
                return changedTitle
            }
            return "标题已更新"
        case .parallelDispatch:
            return ParallelDispatchToolCardContentView.summaryText(for: renderContext)
        case .read:
            if let input = compacted(toolUse.input),
               let command = ToolCardSemanticHelpers.extractCommand(from: input),
               let path = ToolCardSemanticHelpers.extractLikelyPathFromCommand(command) {
                return path
            }
        case .glob:
            if let input = compacted(toolUse.input),
               let command = ToolCardSemanticHelpers.extractCommand(from: input) {
                return ToolCardSemanticHelpers.firstMeaningfulLine(from: command, maxLength: 120)
            }
        default:
            break
        }

        if let output = compacted(toolUse.output), !output.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: output, maxLength: 120)
        }
        if let input = compacted(toolUse.input), !input.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: input, maxLength: 120)
        }
        if let description = compacted(toolUse.description), !description.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: description, maxLength: 120)
        }
        if let reason = compacted(toolUse.permission?.reason), !reason.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: reason, maxLength: 120)
        }
        return statusText
    }

    private func codexCommandSummary() -> String {
        if let command = resolvedCommandPreview() {
            return "$ \(ToolCardSemanticHelpers.firstMeaningfulLine(from: command, maxLength: 120))"
        }

        let summary = CommandToolCardContentView.summaryText(for: renderContext)
        if summary.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("$") {
            return summary
        }
        if looksLikeJSONCommandPreview(summary) {
            if let output = compacted(toolUse.output), !output.isEmpty {
                return "命令结果"
            }
            return "命令执行"
        }
        return summary
    }

    private func changedTitlePreview() -> String? {
        let title = ToolCardSemanticHelpers.extractChangedTitle(from: compacted(toolUse.output))
            ?? ToolCardSemanticHelpers.extractChangedTitle(from: compacted(toolUse.input))
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func resolvedCommandPreview() -> String? {
        if let parsedCommand = CodexToolPayloadResolver.primaryCommand(for: toolUse) {
            return parsedCommand
        }
        let fallback = ToolCardSemanticHelpers.parseBashOutput(toolUse.output)?.command
        let trimmed = fallback?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return nil
        }
        return trimmed
    }

    private func looksLikeJSONCommandPreview(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard trimmed.hasPrefix("$ {") || trimmed.hasPrefix("${") else { return false }
        return trimmed.contains("\"parsed_cmd\"")
            || trimmed.contains("\"source\"")
            || trimmed.contains("payload trimmed")
    }

    private var renderContext: ToolCardRenderContext {
        ToolCardRenderContext(
            toolUse: toolUse,
            providerFlavor: "codex",
            semanticKind: semanticKind,
            taskExecutionSummary: nil,
            resolvedInput: compacted(toolUse.input),
            resolvedOutput: compacted(toolUse.output),
            hasSidecarPayloadRef: {
                let inputRef = toolUse.inputPayloadRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let outputRef = toolUse.outputPayloadRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !inputRef.isEmpty || !outputRef.isEmpty
            }()
        )
    }

    private var supportsDetailSheet: Bool {
        semanticKind != .titleChange
    }

    private var statusText: String {
        switch toolUse.status {
        case .pending: return "Pending"
        case .running: return "Running"
        case .success: return "Completed"
        case .error: return "Failed"
        }
    }

    private var pendingPermission: CLIMessage.ToolUse.Permission? {
        guard let permission = toolUse.permission, permission.status == .pending else { return nil }
        return permission
    }

    private var iconColor: Color {
        switch toolUse.status {
        case .pending:
            return .orange
        case .running:
            return .blue
        case .success:
            return .green
        case .error:
            return .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(iconColor)

                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if supportsDetailSheet {
                    Button {
                        showDetailSheet = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                }
            }

            if isSkillGetTool {
                SkillGetPreviewBlock(
                    snapshot: skillSnapshot,
                    fallbackText: previewText
                )
            } else if isSkillListTool {
                SkillListPreviewBlock(
                    snapshot: skillListSnapshot,
                    fallbackText: previewText
                )
            } else if isSkillCreateTool {
                SkillCreatePreviewBlock(
                    snapshot: skillCreateSnapshot,
                    fallbackText: previewText
                )
            } else if isSkillDeleteTool {
                SkillDeletePreviewBlock(
                    snapshot: skillDeleteSnapshot,
                    fallbackText: previewText
                )
            } else {
                Text(previewText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let permission = pendingPermission {
                HStack(spacing: 8) {
                    Button("Allow") {
                        onAllow?(permission.id)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isActionLoading || onAllow == nil)

                    Button("Session") {
                        onAllowForSession?(permission.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(isActionLoading || onAllowForSession == nil)

                    Button("Deny") {
                        onDeny?(permission.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .controlSize(.small)
                    .disabled(isActionLoading || onDeny == nil)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.black.opacity(0.08), lineWidth: 0.5)
        )
        .sheet(isPresented: $showDetailSheet) {
            Group {
                if isSkillGetTool {
                    SkillGetToolDetailSheet(toolUse: toolUse)
                } else if isSkillListTool {
                    SkillListToolDetailSheet(toolUse: toolUse)
                } else {
                    RawCLIToolDetailSheet(
                        toolUse: toolUse,
                        isActionLoading: isActionLoading,
                        onAllow: onAllow,
                        onAllowForSession: onAllowForSession,
                        onDeny: onDeny
                    )
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func compacted(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
