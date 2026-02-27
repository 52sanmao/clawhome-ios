import SwiftUI
import UIKit

struct CLIRunGroup: Identifiable {
    let id: String
    var runtimeMessages: [CLIMessage] = []
    var updatedAt: Date
    var latestToolMessageIndexById: [String: Int] = [:]
    var mergedToolStateById: [String: CLIMessage.ToolUse] = [:]
}

enum CLIRunGrouper {
    static func build(from messages: [CLIMessage], providerFlavor: String? = nil) -> [CLIRunGroup] {
        let normalizedMessages = normalizeMessagesForProvider(messages, providerFlavor: providerFlavor)
        guard !normalizedMessages.isEmpty else { return [] }

        let ordered = normalizedMessages.sorted(by: messageSortLessThan)
        var groups: [CLIRunGroup] = []
        var currentIndex: Int?

        for message in ordered {
            if isUserBoundaryMessage(message) {
                let groupId = message.runId ?? "run-\(message.id)"
                var group = CLIRunGroup(id: groupId, updatedAt: message.timestamp)
                group.runtimeMessages.append(message)
                groups.append(group)
                currentIndex = groups.count - 1
                continue
            }

            if let currentIndex {
                groups[currentIndex].runtimeMessages.append(message)
                groups[currentIndex].updatedAt = max(groups[currentIndex].updatedAt, message.timestamp)
            } else {
                let groupId = message.runId ?? "run-\(message.id)"
                var group = CLIRunGroup(id: groupId, updatedAt: message.timestamp)
                group.runtimeMessages.append(message)
                groups.append(group)
                currentIndex = groups.count - 1
            }
        }

        for index in groups.indices {
            let projection = makeProjection(from: groups[index].runtimeMessages)
            groups[index].latestToolMessageIndexById = projection.latestIndexById
            groups[index].mergedToolStateById = projection.mergedToolStateById
        }

        return groups
    }

    static func append(
        existing groups: [CLIRunGroup],
        with newMessages: [CLIMessage],
        providerFlavor: String? = nil
    ) -> [CLIRunGroup] {
        guard !newMessages.isEmpty else { return groups }
        let allMessages = groups.flatMap { $0.runtimeMessages } + newMessages
        return build(from: allMessages, providerFlavor: providerFlavor)
    }

    static func refresh(
        existing groups: [CLIRunGroup],
        with messages: [CLIMessage],
        providerFlavor: String? = nil
    ) -> [CLIRunGroup] {
        build(from: messages, providerFlavor: providerFlavor)
    }

    private struct ToolProjection {
        let latestIndexById: [String: Int]
        let mergedToolStateById: [String: CLIMessage.ToolUse]
    }

    private static func makeProjection(from messages: [CLIMessage]) -> ToolProjection {
        var latest: [String: Int] = [:]
        var merged: [String: CLIMessage.ToolUse] = [:]

        for (messageIndex, message) in messages.enumerated() {
            for tool in message.toolUse ?? [] {
                latest[tool.id] = messageIndex
                if let existing = merged[tool.id] {
                    merged[tool.id] = mergeToolState(existing: existing, incoming: tool)
                } else {
                    merged[tool.id] = tool
                }
            }
        }

        return ToolProjection(latestIndexById: latest, mergedToolStateById: merged)
    }

    private static func mergeToolState(
        existing: CLIMessage.ToolUse,
        incoming: CLIMessage.ToolUse
    ) -> CLIMessage.ToolUse {
        var merged = incoming

        if merged.input?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let input = existing.input,
           !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.input = input
        }
        if merged.output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let output = existing.output,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.output = output
        }

        if merged.inputPayloadRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let ref = existing.inputPayloadRef,
           !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.inputPayloadRef = ref
        }
        if merged.outputPayloadRef?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let ref = existing.outputPayloadRef,
           !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.outputPayloadRef = ref
        }

        if merged.inputPayloadSize == nil {
            merged.inputPayloadSize = existing.inputPayloadSize
        }
        if merged.outputPayloadSize == nil {
            merged.outputPayloadSize = existing.outputPayloadSize
        }

        if merged.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
           let description = existing.description,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            merged.description = description
        }

        if merged.permission == nil {
            merged.permission = existing.permission
        }

        merged.status = mergeToolStatus(existing.status, incoming.status)
        merged.executionTime = incoming.executionTime ?? existing.executionTime
        merged.name = preferredToolName(existing: existing.name, incoming: incoming.name)
        return merged
    }

    private static func mergeToolStatus(
        _ lhs: CLIMessage.ToolUse.Status,
        _ rhs: CLIMessage.ToolUse.Status
    ) -> CLIMessage.ToolUse.Status {
        switch rhs {
        case .error:
            return .error
        case .success:
            return lhs == .error ? .error : .success
        case .running:
            return lhs == .pending ? .running : lhs
        case .pending:
            return lhs
        }
    }

    private static func preferredToolName(existing: String, incoming: String) -> String {
        let existingTrimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingTrimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)

        if incomingTrimmed.isEmpty { return existingTrimmed }
        if existingTrimmed.isEmpty { return incomingTrimmed }

        let existingKind = CLIToolSemantics.classifyToolName(existingTrimmed)
        let incomingKind = CLIToolSemantics.classifyToolName(incomingTrimmed)

        // Preserve more specific semantic names (e.g. Explored/Read/Glob)
        // when a trailing result falls back to generic command naming.
        if existingKind == .parallelDispatch
            || existingKind == .read
            || existingKind == .glob
            || existingKind == .fileEdit {
            if incomingKind == .command
                || incomingKind == .generic
                || incomingKind == .protocolFallback {
                return existingTrimmed
            }
        }

        return incomingTrimmed
    }

    private static func messageSortLessThan(_ lhs: CLIMessage, _ rhs: CLIMessage) -> Bool {
        if let lhsSeq = lhs.rawSeq, let rhsSeq = rhs.rawSeq, lhsSeq != rhsSeq {
            return lhsSeq < rhsSeq
        }

        if lhs.timestamp != rhs.timestamp {
            return lhs.timestamp < rhs.timestamp
        }

        let lhsRawId = lhs.rawMessageId ?? lhs.id
        let rhsRawId = rhs.rawMessageId ?? rhs.id
        if lhsRawId != rhsRawId {
            return lhsRawId < rhsRawId
        }
        return lhs.id < rhs.id
    }

    private static func isUserBoundaryMessage(_ message: CLIMessage) -> Bool {
        guard message.role == .user else { return false }
        return !message.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private static func normalizeMessagesForProvider(
        _ messages: [CLIMessage],
        providerFlavor: String?
    ) -> [CLIMessage] {
        guard isClaudeFlavor(providerFlavor) else { return messages }
        return ClaudeACPMessageNormalizer.normalize(messages)
    }

    private static func isClaudeFlavor(_ providerFlavor: String?) -> Bool {
        let normalized = providerFlavor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return normalized == "claude" || normalized == "claudecode"
    }
}

struct CLIRunGroupView: View {
    let group: CLIRunGroup
    let providerFlavor: String?
    let hasActiveRun: Bool
    let isLatestGroup: Bool
    let permissionActionInFlight: Set<String>
    let onAllowPermission: (String) -> Void
    let onAllowPermissionForSession: (String) -> Void
    let onDenyPermission: (String) -> Void
    
    private var isCodexFlavor: Bool {
        providerFlavor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "codex"
    }

    private var isOpenCodeFlavor: Bool {
        providerFlavor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "opencode"
    }

    private var isClaudeFlavor: Bool {
        let normalized = providerFlavor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
        return normalized == "claude" || normalized == "claudecode"
    }

    private var shouldShowTimestamp: Bool {
        !(hasActiveRun && isLatestGroup)
    }

    var body: some View {
        Group {
            if isCodexFlavor {
                CodexRunGroupView(
                    group: group,
                    hasActiveRun: hasActiveRun,
                    isLatestGroup: isLatestGroup,
                    permissionActionInFlight: permissionActionInFlight,
                    onAllowPermission: onAllowPermission,
                    onAllowPermissionForSession: onAllowPermissionForSession,
                    onDenyPermission: onDenyPermission
                )
            } else if isOpenCodeFlavor {
                OpenCodeRunGroupView(
                    group: group,
                    hasActiveRun: hasActiveRun,
                    isLatestGroup: isLatestGroup,
                    permissionActionInFlight: permissionActionInFlight,
                    onAllowPermission: onAllowPermission,
                    onAllowPermissionForSession: onAllowPermissionForSession,
                    onDenyPermission: onDenyPermission
                )
            } else if isClaudeFlavor {
                ClaudeRunGroupView(
                    group: group,
                    hasActiveRun: hasActiveRun,
                    isLatestGroup: isLatestGroup,
                    permissionActionInFlight: permissionActionInFlight,
                    onAllowPermission: onAllowPermission,
                    onAllowPermissionForSession: onAllowPermissionForSession,
                    onDenyPermission: onDenyPermission
                )
            } else {
                GenericRunGroupView(
                    group: group,
                    shouldShowTimestamp: shouldShowTimestamp,
                    permissionActionInFlight: permissionActionInFlight,
                    onAllowPermission: onAllowPermission,
                    onAllowPermissionForSession: onAllowPermissionForSession,
                    onDenyPermission: onDenyPermission
                )
            }
        }
    }
}

private struct GenericRunGroupView: View {
    let group: CLIRunGroup
    let shouldShowTimestamp: Bool
    let permissionActionInFlight: Set<String>
    let onAllowPermission: (String) -> Void
    let onAllowPermissionForSession: (String) -> Void
    let onDenyPermission: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(renderableRuntimeMessages, id: \.message.id) { entry in
                CLIRuntimeMessageView(
                    message: entry.message,
                    messageIndex: entry.index,
                    latestToolMessageIndexById: group.latestToolMessageIndexById,
                    mergedToolStateById: group.mergedToolStateById,
                    suppressedToolIDs: [],
                    toolCardRenderer: { tool in
                        AnyView(
                            GenericProtocolToolEventCard(
                                toolUse: tool,
                                isActionLoading: permissionActionInFlight.contains(tool.permission?.id ?? ""),
                                onAllow: { id in onAllowPermission(id) },
                                onAllowForSession: { id in onAllowPermissionForSession(id) },
                                onDeny: { id in onDenyPermission(id) }
                            )
                        )
                    }
                )
            }

            if shouldShowTimestamp,
               let timestamp = group.runtimeMessages.last?.timestamp {
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 2)
    }

    private var renderableRuntimeMessages: [(index: Int, message: CLIMessage)] {
        Array(group.runtimeMessages.enumerated()).compactMap { index, message in
            if shouldRender(message: message, messageIndex: index) {
                return (index, message)
            }
            return nil
        }
    }

    private func shouldRenderTextContent(for message: CLIMessage) -> Bool {
        if message.role == .user {
            return !message.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !CLIRuntimeTextNormalizer.normalizedAssistantTexts(from: message).isEmpty
    }

    private func shouldRender(message: CLIMessage, messageIndex: Int) -> Bool {
        if shouldRenderTextContent(for: message) {
            return true
        }

        let hasVisibleTools = (message.toolUse ?? []).contains { tool in
            return group.latestToolMessageIndexById[tool.id] == messageIndex
        }
        return hasVisibleTools
    }
}

struct CLIRuntimeMessageView: View {
    let message: CLIMessage
    let messageIndex: Int
    let latestToolMessageIndexById: [String: Int]
    let mergedToolStateById: [String: CLIMessage.ToolUse]
    let suppressedToolIDs: Set<String>
    let usesCompactMarkdownHeadings: Bool
    let toolCardRenderer: (CLIMessage.ToolUse) -> AnyView

    init(
        message: CLIMessage,
        messageIndex: Int,
        latestToolMessageIndexById: [String: Int],
        mergedToolStateById: [String: CLIMessage.ToolUse],
        suppressedToolIDs: Set<String>,
        usesCompactMarkdownHeadings: Bool = false,
        toolCardRenderer: @escaping (CLIMessage.ToolUse) -> AnyView
    ) {
        self.message = message
        self.messageIndex = messageIndex
        self.latestToolMessageIndexById = latestToolMessageIndexById
        self.mergedToolStateById = mergedToolStateById
        self.suppressedToolIDs = suppressedToolIDs
        self.usesCompactMarkdownHeadings = usesCompactMarkdownHeadings
        self.toolCardRenderer = toolCardRenderer
    }

    private var visibleTools: [CLIMessage.ToolUse] {
        let sourceTools = message.toolUse ?? []
        var deduped: [CLIMessage.ToolUse] = []
        var seen = Set<String>()

        for tool in sourceTools {
            guard !suppressedToolIDs.contains(tool.id) else { continue }
            guard latestToolMessageIndexById[tool.id] == messageIndex else { continue }
            let resolved = mergedToolStateById[tool.id] ?? tool
            if seen.insert(resolved.id).inserted {
                deduped.append(resolved)
            }
        }

        return deduped
    }

    private var assistantTexts: [String] {
        CLIRuntimeTextNormalizer.normalizedAssistantTexts(from: message)
    }

    private var systemStatusText: String {
        let joined = message.content
            .filter { $0.type == .text || $0.type == .event }
            .compactMap { $0.text?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return joined.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedSkillLabel: String? {
        if let explicitName = message.selectedSkillName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitName.isEmpty {
            return explicitName
        }

        guard let uri = message.selectedSkillUri?.trimmingCharacters(in: .whitespacesAndNewlines),
              !uri.isEmpty else {
            return nil
        }

        if let tail = uri.split(separator: "/").last {
            let candidate = String(tail).trimmingCharacters(in: .whitespacesAndNewlines)
            return candidate.isEmpty ? nil : candidate
        }
        return nil
    }

    var body: some View {
        let isUser = message.role == .user
        let isSystem = message.role == .system

        Group {
            if isSystem {
                if !systemStatusText.isEmpty {
                    HStack {
                        Spacer(minLength: 0)
                        Text(systemStatusText)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    if isUser { Spacer(minLength: 0) }

                    VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                        if isUser {
                            userBubble
                        } else {
                            assistantContent

                            if !visibleTools.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(visibleTools, id: \.id) { tool in
                                        toolCardRenderer(tool)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)

                    if !isUser { Spacer(minLength: 0) }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    @ViewBuilder
    private var userBubble: some View {
        let userText = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userText.isEmpty {
            VStack(alignment: .trailing, spacing: 6) {
                if let selectedSkillLabel {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.system(size: 10, weight: .semibold))
                        Text("已加载技能: \(selectedSkillLabel)")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.green.opacity(0.12))
                    .clipShape(Capsule(style: .continuous))
                }

                Text(message.displayText)
                    .font(.system(size: 15))
                    .foregroundColor(.primary)
                    .padding(12)
                    .background(Color(.systemGray5))
                    .cornerRadius(16)
                    .contextMenu {
                        Button {
                            copyUserMessageText()
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                    }
            }
        }
    }

    private func copyUserMessageText() {
        let text = message.displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
    }

    @ViewBuilder
    private var assistantContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(assistantTexts.enumerated()), id: \.offset) { _, text in
                MarkdownText(
                    markdown: text,
                    isUserMessage: false,
                    allowPlainTextFallback: false,
                    headingStyle: usesCompactMarkdownHeadings ? .compact : .standard
                )
                    .textSelection(.enabled)
            }
        }
    }
}

enum CLIRuntimeTextNormalizer {
    static func normalizedAssistantTexts(from message: CLIMessage) -> [String] {
        message.content.compactMap { block in
            guard block.type == .text else { return nil }
            return normalizeAssistantText(block.text)
        }
    }

    private static func normalizeAssistantText(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let unified = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let strippedControl = stripInvisibleControlCharacters(unified)
        let collapsedBlankLines = collapseExcessiveBlankLines(strippedControl)
        let edgeTrimmed = trimEdgeBlankLines(collapsedBlankLines)
            .trimmingTrailingWhitespaceAndNewlines()
        let visibleCheck = edgeTrimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visibleCheck.isEmpty else { return nil }
        return edgeTrimmed
    }

    private static func stripInvisibleControlCharacters(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" {
                return true
            }
            return !CharacterSet.controlCharacters.contains(scalar)
        }))
    }

    private static func collapseExcessiveBlankLines(_ text: String) -> String {
        var result = ""
        var newlineStreak = 0
        for char in text {
            if char == "\n" {
                newlineStreak += 1
                if newlineStreak <= 2 {
                    result.append(char)
                }
            } else {
                newlineStreak = 0
                result.append(char)
            }
        }
        return result
    }

    private static func trimEdgeBlankLines(_ text: String) -> String {
        var chars = Array(text)
        while let first = chars.first, first == "\n" || first == "\r" {
            chars.removeFirst()
        }
        while let last = chars.last, last == "\n" || last == "\r" {
            chars.removeLast()
        }
        return String(chars)
    }
}

private extension String {
    func trimmingTrailingWhitespaceAndNewlines() -> String {
        var scalars = unicodeScalars
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

private struct GenericProtocolToolEventCard: View {
    let toolUse: CLIMessage.ToolUse
    var isActionLoading: Bool = false
    var onAllow: ((String) -> Void)? = nil
    var onAllowForSession: ((String) -> Void)? = nil
    var onDeny: ((String) -> Void)? = nil

    @State private var showDetailSheet = false

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
        let trimmed = toolUse.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "protocol.event" : trimmed
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

        if let output = compacted(toolUse.output), !output.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: output, maxLength: 120)
        }
        if let input = compacted(toolUse.input), !input.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: input, maxLength: 120)
        }
        if let description = compacted(toolUse.description), !description.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: description, maxLength: 120)
        }
        return "Protocol event"
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

    private var pendingPermission: CLIMessage.ToolUse.Permission? {
        guard let permission = toolUse.permission, permission.status == .pending else { return nil }
        return permission
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isSkillGetTool
                      ? "book.closed"
                      : (isSkillListTool
                         ? "list.bullet.rectangle"
                         : (isSkillCreateTool
                            ? "plus.circle"
                            : (isSkillDeleteTool ? "trash" : "square.stack.3d.up"))))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(iconColor)

                Text(displayName)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

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
                .fill(Color(.tertiarySystemGroupedBackground))
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

struct RawCLIToolDetailSheet: View {
    let toolUse: CLIMessage.ToolUse
    var isActionLoading: Bool = false
    var onAllow: ((String) -> Void)? = nil
    var onAllowForSession: ((String) -> Void)? = nil
    var onDeny: ((String) -> Void)? = nil

    private var displayName: String {
        let trimmed = toolUse.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Tool" : trimmed
    }

    private var inputText: String {
        prettified(toolUse.input)
    }

    private var outputText: String {
        prettified(toolUse.output)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        StatusBadge(status: toolUse.status)
                        Spacer(minLength: 0)
                        Text(toolUse.id)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    if let permission = toolUse.permission {
                        DetailSection(title: "Permission", icon: "lock.shield", copyText: permission.reason) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Status: \(permission.status.rawValue)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.secondary)
                                if let reason = permission.reason,
                                   !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(reason)
                                        .font(.system(size: 12))
                                        .foregroundColor(.primary)
                                }

                            }
                        }
                    }

                    if !inputText.isEmpty {
                        DetailSection(title: "Raw ACP payload", icon: "doc.text", copyText: inputText) {
                            CodeBlock(text: inputText)
                        }
                    }

                    if !outputText.isEmpty {
                        DetailSection(title: "Raw result payload", icon: "doc.plaintext", copyText: outputText) {
                            CodeBlock(text: outputText)
                        }
                    }

                    if let inputRef = toolUse.inputPayloadRef,
                       !inputRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSection(title: "Input payload ref", icon: "link", copyText: inputRef) {
                            Text(inputRef)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundColor(.primary)
                        }
                    }

                    if let outputRef = toolUse.outputPayloadRef,
                       !outputRef.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSection(title: "Output payload ref", icon: "link", copyText: outputRef) {
                            Text(outputRef)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                                .foregroundColor(.primary)
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

extension RawCLIToolDetailSheet {
    private func prettified(_ raw: String?) -> String {
        guard let raw else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object),
              let prettyData = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let pretty = String(data: prettyData, encoding: .utf8) else {
            return trimmed
        }
        return pretty
    }
}
