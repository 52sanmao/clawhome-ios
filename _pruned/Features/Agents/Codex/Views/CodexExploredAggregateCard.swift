import SwiftUI

struct CodexExploredAggregateCard: View {
    let tools: [CLIMessage.ToolUse]

    private struct Row: Identifiable {
        let id: String
        let text: String
        let status: CLIMessage.ToolUse.Status
    }

    private static let maxVisibleRows = 8

    private var rows: [Row] {
        tools.map { tool in
            let line = summarizedLine(for: tool)
            return Row(id: tool.id, text: line, status: tool.status)
        }
    }

    private var visibleRows: [Row] {
        Array(rows.prefix(Self.maxVisibleRows))
    }

    private var hiddenCount: Int {
        max(0, rows.count - visibleRows.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.down.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.blue)

                Text("Explored")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(visibleRows) { row in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: iconName(for: row.status))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(iconColor(for: row.status))
                            .frame(width: 12)

                        Text(row.text)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if hiddenCount > 0 {
                    Text("…还有 \(hiddenCount) 项")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
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
    }

    private func summarizedLine(for tool: CLIMessage.ToolUse) -> String {
        let operations = CodexToolPayloadResolver.exploreOperations(for: tool)
        if !operations.isEmpty {
            let actionLabel = compactOperationTitles(operations)
            let detail = operations
                .compactMap { value in
                    let trimmed = (value.detail ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                .first

            if let detail {
                if operations.count > 1 {
                    return "\(actionLabel) \(detail) (+\(operations.count - 1))"
                }
                return "\(actionLabel) \(detail)"
            }

            if operations.count > 1 {
                return "\(actionLabel) (+\(operations.count - 1))"
            }
            return actionLabel
        }

        if let command = ToolCardSemanticHelpers.extractCommand(from: tool.input),
           !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let subtypeLabel = commandSubtypeLabel(for: command)
            let summary = ToolCardSemanticHelpers.firstMeaningfulLine(from: command, maxLength: 120)
            return "\(subtypeLabel) \(summary)"
        }

        if let output = tool.output,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let summary = ToolCardSemanticHelpers.firstMeaningfulLine(from: output, maxLength: 120)
            return "Command \(summary)"
        }

        let fallback = tool.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "Command" : "Command \(fallback)"
    }

    private func compactOperationTitles(_ operations: [ParallelDispatchOperationSnapshot]) -> String {
        var seen = Set<String>()
        var ordered: [String] = []
        for op in operations {
            let title = op.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = title.lowercased()
            if seen.insert(key).inserted {
                ordered.append(title)
            }
        }

        if ordered.isEmpty { return "Command" }
        ordered = ordered.map { label in
            label.lowercased() == "run" ? "Command" : label
        }
        return ordered.joined(separator: "/")
    }

    private func commandSubtypeLabel(for command: String) -> String {
        switch ToolCardSemanticHelpers.classifyCommandSubtype(command) {
        case .search:
            return "Search"
        case .read:
            return "Read"
        case .list:
            return "List"
        case .generic:
            return "Command"
        }
    }

    private func iconName(for status: CLIMessage.ToolUse.Status) -> String {
        switch status {
        case .pending:
            return "circle.dotted"
        case .running:
            return "clock"
        case .success:
            return "checkmark.circle.fill"
        case .error:
            return "xmark.octagon.fill"
        }
    }

    private func iconColor(for status: CLIMessage.ToolUse.Status) -> Color {
        switch status {
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
}

struct CodexRunGroupView: View {
    let group: CLIRunGroup
    let hasActiveRun: Bool
    let isLatestGroup: Bool
    let permissionActionInFlight: Set<String>
    let onAllowPermission: (String) -> Void
    let onAllowPermissionForSession: (String) -> Void
    let onDenyPermission: (String) -> Void

    private var shouldShowTimestamp: Bool {
        !(hasActiveRun && isLatestGroup)
    }

    private var exploreSegments: [CodexExploreSegment] {
        CodexExploreAggregation.segments(
            groupId: group.id,
            runtimeMessages: group.runtimeMessages,
            latestToolMessageIndexById: group.latestToolMessageIndexById,
            mergedToolStateById: group.mergedToolStateById
        )
    }

    private var exploreSegmentByBeforeIndex: [Int: [CodexExploreSegment]] {
        var grouped: [Int: [CodexExploreSegment]] = [:]
        for segment in exploreSegments {
            guard let index = segment.beforeMessageIndex else { continue }
            grouped[index, default: []].append(segment)
        }
        return grouped
    }

    private var trailingExploreSegments: [CodexExploreSegment] {
        exploreSegments.filter { $0.beforeMessageIndex == nil }
    }

    private var suppressedToolIDs: Set<String> {
        Set(exploreSegments.flatMap { $0.tools.map(\.id) })
    }

    private var renderableRuntimeMessages: [(index: Int, message: CLIMessage)] {
        Array(group.runtimeMessages.enumerated()).compactMap { index, message in
            if shouldRender(message: message, messageIndex: index) {
                return (index, message)
            }
            return nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(renderableRuntimeMessages, id: \.message.id) { entry in
                if let segments = exploreSegmentByBeforeIndex[entry.index] {
                    ForEach(segments) { segment in
                        CodexExploredAggregateCard(tools: segment.tools)
                            .padding(.horizontal, 16)
                    }
                }

                CLIRuntimeMessageView(
                    message: entry.message,
                    messageIndex: entry.index,
                    latestToolMessageIndexById: group.latestToolMessageIndexById,
                    mergedToolStateById: group.mergedToolStateById,
                    suppressedToolIDs: suppressedToolIDs,
                    toolCardRenderer: { tool in
                        AnyView(
                            CodexToolEventCard(
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

            if !trailingExploreSegments.isEmpty {
                ForEach(trailingExploreSegments) { segment in
                    CodexExploredAggregateCard(tools: segment.tools)
                        .padding(.horizontal, 16)
                }
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

    private func shouldRender(message: CLIMessage, messageIndex: Int) -> Bool {
        if shouldRenderTextContent(for: message) {
            return true
        }

        let hasVisibleTools = (message.toolUse ?? []).contains { tool in
            guard !suppressedToolIDs.contains(tool.id) else { return false }
            return group.latestToolMessageIndexById[tool.id] == messageIndex
        }
        return hasVisibleTools
    }

    private func shouldRenderTextContent(for message: CLIMessage) -> Bool {
        if message.role == .user {
            return !message.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !CLIRuntimeTextNormalizer.normalizedAssistantTexts(from: message).isEmpty
    }
}
