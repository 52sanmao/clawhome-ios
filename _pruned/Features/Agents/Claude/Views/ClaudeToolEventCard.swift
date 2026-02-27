import Foundation
import SwiftUI

private enum ClaudeToolDetailSheet: String, Identifiable {
    case raw
    case command
    case skill
    case skillList

    var id: String { rawValue }
}

private struct ClaudeResolvedToolDescriptor {
    var toolUse: CLIMessage.ToolUse
    let semanticKind: CLIToolCardKind
    let eventName: String?
    let previewHint: String?
}

private struct ClaudeRawEventDescriptor {
    let eventName: String?
    let toolName: String?
    let kind: String?
    let title: String?
    let status: CLIMessage.ToolUse.Status?
    let input: String?
    let output: String?
    let previewHint: String?
}

private enum ClaudeToolPayloadResolver {
    static func resolve(toolUse: CLIMessage.ToolUse) -> ClaudeResolvedToolDescriptor {
        let isProtocolFallback = CLIToolSemantics.isProtocolFallbackName(toolUse.name)
        let rawEvent = parseRawDescriptor(from: toolUse.output) ?? parseRawDescriptor(from: toolUse.input)

        var resolved = toolUse
        var previewHint: String?
        var eventName = rawEvent?.eventName

        if let rawEvent {
            let fallbackName = rawEvent.toolName ?? rawEvent.kind ?? rawEvent.title
            if shouldOverrideToolName(current: resolved.name, isProtocolFallback: isProtocolFallback),
               let fallbackName,
               !fallbackName.isEmpty {
                resolved.name = CLIToolSemantics.canonicalToolName(fallbackName)
            }

            if isProtocolFallback, let status = rawEvent.status ?? deriveStatus(fromEventName: rawEvent.eventName) {
                resolved.status = status
            }

            if (resolved.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               let title = rawEvent.title,
               !title.isEmpty {
                resolved.description = title
            }

            if (resolved.input?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
               let input = rawEvent.input,
               !input.isEmpty {
                resolved.input = input
            }

            if isProtocolFallback,
               shouldReplaceFallbackOutput(resolved.output),
               let output = rawEvent.output,
               !output.isEmpty {
                resolved.output = output
            }

            if !resolved.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                eventName = rawEvent.eventName ?? eventName
            }
            previewHint = rawEvent.previewHint
        }

        if shouldOverrideToolName(current: resolved.name, isProtocolFallback: isProtocolFallback),
           let inferredName = inferFallbackName(from: eventName),
           !inferredName.isEmpty {
            resolved.name = inferredName
        }

        let semanticKind = CLIToolSemantics.classifyToolName(resolved.name)
        return ClaudeResolvedToolDescriptor(
            toolUse: resolved,
            semanticKind: semanticKind,
            eventName: eventName,
            previewHint: previewHint
        )
    }

    private static func shouldOverrideToolName(current: String, isProtocolFallback: Bool) -> Bool {
        if isProtocolFallback { return true }
        let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return trimmed.caseInsensitiveCompare("tool") == .orderedSame
    }

    private static func shouldReplaceFallbackOutput(_ output: String?) -> Bool {
        guard let output else { return true }
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.hasPrefix("[未适配协议事件]")
    }

    private static func inferFallbackName(from eventName: String?) -> String? {
        guard let eventName else { return nil }
        let lowered = eventName.lowercased()
        if lowered.contains("tool_call") || lowered.contains("tool_result") || lowered.contains("tool") {
            return "Tool"
        }
        let pretty = eventName
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return pretty.isEmpty ? nil : pretty
    }

    private static func parseRawDescriptor(from raw: String?) -> ClaudeRawEventDescriptor? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let fallback = parseFallbackOutput(trimmed)
        let payloadTextCandidate = fallback.payload ?? trimmed

        guard let payloadValue = ToolUseJSONParser.parseJSON(payloadTextCandidate) else {
            return nil
        }
        return parsePayload(value: payloadValue, fallbackEventName: fallback.eventName)
    }

    private static func parsePayload(
        value: Any,
        fallbackEventName: String?
    ) -> ClaudeRawEventDescriptor? {
        guard let dict = value as? [String: Any] else { return nil }

        var eventName = nonEmptyString(dict["name"]) ?? fallbackEventName
        var payload: Any = dict
        if let type = nonEmptyString(dict["type"])?.lowercased(), type == "event" {
            payload = dict["payload"] ?? dict
            eventName = nonEmptyString(dict["name"]) ?? eventName
        }

        let payloadDict = payload as? [String: Any]
        let toolName = firstNonEmptyString([
            dictionaryValue(payloadDict, path: ["_meta", "claudeCode", "toolName"]),
            payloadDict?["toolName"],
            payloadDict?["name"],
            payloadDict?["kind"],
            payloadDict?["title"]
        ])
        let kind = nonEmptyString(payloadDict?["kind"])
        let title = nonEmptyString(payloadDict?["title"])
        let status = parseStatus(from: payloadDict?["status"]) ?? parseStatus(from: payloadDict?["state"])
        let input = stringify(
            payloadDict?["rawInput"]
                ?? payloadDict?["input"]
                ?? payloadDict?["params"]
                ?? payloadDict?["arguments"]
                ?? payloadDict?["payload"]
        )
        let output = stringify(
            payloadDict?["result"]
                ?? payloadDict?["output"]
                ?? payloadDict?["content"]
                ?? payloadDict?["text"]
        )
        let previewHint = buildPreviewHint(
            title: title,
            kind: kind,
            payloadDict: payloadDict
        )

        if eventName == nil,
           toolName == nil,
           kind == nil,
           title == nil,
           input == nil,
           output == nil {
            return nil
        }

        return ClaudeRawEventDescriptor(
            eventName: eventName,
            toolName: toolName,
            kind: kind,
            title: title,
            status: status,
            input: input,
            output: output,
            previewHint: previewHint
        )
    }

    private static func buildPreviewHint(
        title: String?,
        kind: String?,
        payloadDict: [String: Any]?
    ) -> String? {
        if let title, !title.isEmpty {
            return title
        }

        if let locations = payloadDict?["locations"] as? [Any] {
            for location in locations {
                guard let dict = location as? [String: Any] else { continue }
                let path = firstNonEmptyString([
                    dict["path"],
                    dict["uri"],
                    dict["file"],
                    dict["target"]
                ])
                if let path, !path.isEmpty {
                    return path
                }
            }
        }

        if let kind, !kind.isEmpty {
            return kind
        }

        return nil
    }

    private static func parseStatus(from value: Any?) -> CLIMessage.ToolUse.Status? {
        guard let raw = nonEmptyString(value)?.lowercased() else { return nil }

        if ["error", "failed", "failure", "aborted", "denied", "canceled", "cancelled"].contains(raw) {
            return .error
        }
        if ["success", "completed", "complete", "done", "ok"].contains(raw) {
            return .success
        }
        if ["running", "started", "in_progress", "active"].contains(raw) {
            return .running
        }
        if ["pending", "queued", "waiting"].contains(raw) {
            return .pending
        }
        return nil
    }

    private static func deriveStatus(fromEventName eventName: String?) -> CLIMessage.ToolUse.Status? {
        guard let eventName else { return nil }
        let lowered = eventName.lowercased()

        if lowered.contains("error") || lowered.contains("failed") || lowered.contains("aborted") {
            return .error
        }
        if lowered.contains("result") || lowered.contains("complete") || lowered.contains("finished") {
            return .success
        }
        if lowered.contains("update") || lowered.contains("progress") || lowered.contains("running") {
            return .running
        }
        if lowered.contains("tool_call") {
            return .pending
        }
        return nil
    }

    private static func parseFallbackOutput(_ raw: String) -> (eventName: String?, payload: String?) {
        let marker = "[未适配协议事件]"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(marker) else {
            return (nil, nil)
        }

        let lineParts = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let eventName = lineParts.first.map(String.init)?
            .replacingOccurrences(of: marker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = lineParts.count > 1
            ? String(lineParts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        return (eventName?.isEmpty == true ? nil : eventName, payload?.isEmpty == true ? nil : payload)
    }

    private static func dictionaryValue(_ dict: [String: Any]?, path: [String]) -> Any? {
        guard let dict else { return nil }
        guard let first = path.first else { return nil }
        if path.count == 1 {
            return dict[first]
        }
        guard let nested = dict[first] as? [String: Any] else { return nil }
        return dictionaryValue(nested, path: Array(path.dropFirst()))
    }

    private static func firstNonEmptyString(_ values: [Any?]) -> String? {
        for value in values {
            if let resolved = nonEmptyString(value), !resolved.isEmpty {
                return resolved
            }
        }
        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private static func stringify(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: []),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ClaudeToolEventCard: View {
    let toolUse: CLIMessage.ToolUse
    var isActionLoading: Bool = false
    var onAllow: ((String) -> Void)? = nil
    var onAllowForSession: ((String) -> Void)? = nil
    var onDeny: ((String) -> Void)? = nil

    @State private var activeSheet: ClaudeToolDetailSheet?

    private var resolved: ClaudeResolvedToolDescriptor {
        ClaudeToolPayloadResolver.resolve(toolUse: toolUse)
    }

    private var semanticKind: CLIToolCardKind {
        resolved.semanticKind
    }

    private var isSkillGetTool: Bool {
        ToolCardSemanticHelpers.isSkillGetToolName(resolved.toolUse.name)
    }

    private var isSkillListTool: Bool {
        ToolCardSemanticHelpers.isSkillListToolName(resolved.toolUse.name)
    }

    private var isSkillCreateTool: Bool {
        ToolCardSemanticHelpers.isSkillCreateToolName(resolved.toolUse.name)
    }

    private var isSkillDeleteTool: Bool {
        ToolCardSemanticHelpers.isSkillDeleteToolName(resolved.toolUse.name)
    }

    private var skillSnapshot: SkillGetCardSnapshot? {
        ToolCardSemanticHelpers.skillGetPreviewSnapshot(for: resolved.toolUse)
    }

    private var skillListSnapshot: SkillListCardSnapshot? {
        ToolCardSemanticHelpers.skillListPreviewSnapshot(for: resolved.toolUse)
    }

    private var skillCreateSnapshot: SkillCreateCardSnapshot? {
        ToolCardSemanticHelpers.skillCreatePreviewSnapshot(for: resolved.toolUse)
    }

    private var skillDeleteSnapshot: SkillDeleteCardSnapshot? {
        ToolCardSemanticHelpers.skillDeletePreviewSnapshot(for: resolved.toolUse)
    }

    private var isPermissionCard: Bool {
        resolved.toolUse.permission != nil
    }

    private var permissionStatusText: String {
        guard let status = resolved.toolUse.permission?.status else {
            return statusText
        }
        switch status {
        case .pending:
            return "Pending"
        case .approved:
            return "Approved"
        case .denied:
            return "Denied"
        case .canceled:
            return "Canceled"
        }
    }

    private var permissionStatusColor: Color {
        guard let status = resolved.toolUse.permission?.status else {
            return iconColor
        }
        switch status {
        case .pending:
            return .orange
        case .approved:
            return .green
        case .denied, .canceled:
            return .red
        }
    }

    private var context: ToolCardRenderContext {
        ToolCardRenderContext(
            toolUse: resolved.toolUse,
            providerFlavor: "claude",
            semanticKind: semanticKind,
            taskExecutionSummary: nil,
            resolvedInput: compacted(resolved.toolUse.input),
            resolvedOutput: compacted(resolved.toolUse.output),
            hasSidecarPayloadRef: {
                let inputRef = resolved.toolUse.inputPayloadRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let outputRef = resolved.toolUse.outputPayloadRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !inputRef.isEmpty || !outputRef.isEmpty
            }()
        )
    }

    private var displayName: String {
        if isPermissionCard {
            return "Permission"
        }
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
        let fallback = resolved.toolUse.name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch semanticKind {
        case .command:
            return "Bash"
        case .parallelDispatch:
            return "ParallelToolUse"
        case .read:
            return "Read"
        case .glob:
            return "Glob"
        case .fileEdit:
            return "Edit"
        case .todo:
            return "TodoWrite"
        case .task:
            return "Task"
        case .backgroundTask:
            return "BackgroundTask"
        case .sessionControl:
            return "SessionControl"
        case .webSearch:
            return "WebSearch"
        case .titleChange:
            return "标题更新"
        case .reasoning:
            return "Reasoning"
        case .protocolFallback, .generic:
            if !fallback.isEmpty {
                return CLIToolSemantics.canonicalToolName(fallback)
            }
            if let eventName = resolved.eventName, !eventName.isEmpty {
                return eventName
            }
            return "Tool"
        }
    }

    private var iconName: String {
        if isPermissionCard {
            return "lock.shield"
        }
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
            return CommandToolCardContentView.iconName(for: context)
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

    private var iconColor: Color {
        switch resolved.toolUse.status {
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

    private var statusText: String {
        switch resolved.toolUse.status {
        case .pending:
            return "Pending"
        case .running:
            return "Running"
        case .success:
            return "Completed"
        case .error:
            return "Failed"
        }
    }

    private var previewText: String {
        if isPermissionCard {
            if let reason = compacted(resolved.toolUse.permission?.reason), !reason.isEmpty {
                return ToolCardSemanticHelpers.firstMeaningfulLine(from: reason, maxLength: 120)
            }
            if let mode = compacted(resolved.toolUse.permission?.mode), !mode.isEmpty {
                return "mode: \(mode)"
            }
            return statusText
        }

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

        if semanticKind == .command,
           let command = resolvedCommandPreview(),
           !command.isEmpty {
            return "$ \(ToolCardSemanticHelpers.firstMeaningfulLine(from: command, maxLength: 120))"
        }

        if semanticKind == .read,
           let readPath = resolvedReadPathPreview(),
           !readPath.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: readPath, maxLength: 120)
        }

        if semanticKind == .glob,
           let pattern = resolvedGlobPatternPreview(),
           !pattern.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: pattern, maxLength: 120)
        }

        if let hint = compacted(resolved.previewHint), !hint.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: hint, maxLength: 120)
        }

        if let output = compacted(resolved.toolUse.output),
           !output.hasPrefix("[未适配协议事件]"),
           !output.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: output, maxLength: 120)
        }
        if let input = compacted(resolved.toolUse.input), !input.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: input, maxLength: 120)
        }
        if let description = compacted(resolved.toolUse.description), !description.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: description, maxLength: 120)
        }
        if let eventName = compacted(resolved.eventName), !eventName.isEmpty {
            return eventName
        }
        return statusText
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

                StatusBadge(status: resolved.toolUse.status)

                if !isPermissionCard {
                    Button {
                        if isSkillGetTool {
                            activeSheet = .skill
                        } else if isSkillListTool {
                            activeSheet = .skillList
                        } else {
                            activeSheet = (semanticKind == .command) ? .command : .raw
                        }
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
                    .lineLimit(2)
                    .truncationMode(.tail)
            }

            if isPermissionCard, let permission = resolved.toolUse.permission {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(permissionStatusColor)
                            .frame(width: 7, height: 7)
                        Text("Status: \(permissionStatusText)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }

                    if permission.status == .pending {
                        HStack(spacing: 8) {
                            Button("Allow") {
                                onAllow?(permission.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isActionLoading)

                            Button("Session") {
                                onAllowForSession?(permission.id)
                            }
                            .buttonStyle(.bordered)
                            .disabled(isActionLoading)

                            Button("Deny") {
                                onDeny?(permission.id)
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                            .disabled(isActionLoading)
                        }
                    }
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
        .sheet(item: $activeSheet) { sheet in
            detailSheet(for: sheet)
                .presentationDetents([.medium, .large])
        }
    }

    @ViewBuilder
    private func detailSheet(for sheet: ClaudeToolDetailSheet) -> some View {
        switch sheet {
        case .raw:
            RawCLIToolDetailSheet(
                toolUse: resolved.toolUse,
                isActionLoading: isActionLoading,
                onAllow: onAllow,
                onAllowForSession: onAllowForSession,
                onDeny: onDeny
            )
        case .command:
            CommandToolCardDetailSheetView(
                context: context,
                loadState: ToolCardDetailLoadState(isLoading: false, errorMessage: nil),
                onClose: { activeSheet = nil }
            )
        case .skill:
            SkillGetToolDetailSheet(toolUse: resolved.toolUse)
        case .skillList:
            SkillListToolDetailSheet(toolUse: resolved.toolUse)
        }
    }

    private func resolvedCommandPreview() -> String? {
        let candidates: [String?] = [
            ToolCardSemanticHelpers.extractCommand(from: resolved.toolUse.input),
            ToolCardSemanticHelpers.parseBashOutput(resolved.toolUse.output)?.command,
            compacted(resolved.previewHint),
            compacted(resolved.toolUse.description)
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()
            if lowered == "terminal" || lowered == "bash" || lowered == "execute" {
                continue
            }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                continue
            }
            return trimmed
        }

        return nil
    }

    private func resolvedReadPathPreview() -> String? {
        let candidates: [String?] = [
            ToolCardSemanticHelpers.summarizeReadPayload(from: resolved.toolUse.input),
            ToolCardSemanticHelpers.summarizeReadPayload(from: resolved.toolUse.output),
            extractPathField(from: resolved.toolUse.input),
            extractPathField(from: resolved.toolUse.output),
            compacted(resolved.previewHint)
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()
            if lowered == "read" || lowered == "read file" || lowered == "file" {
                continue
            }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                continue
            }
            return trimmed
        }

        return nil
    }

    private func resolvedGlobPatternPreview() -> String? {
        let candidates: [String?] = [
            extractPatternField(from: resolved.toolUse.input),
            extractPatternField(from: resolved.toolUse.output),
            compacted(resolved.previewHint)
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let lowered = trimmed.lowercased()
            if lowered == "glob" || lowered == "search" {
                continue
            }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                continue
            }
            return trimmed
        }

        return nil
    }

    private func extractPathField(from raw: String?) -> String? {
        guard let raw else { return nil }
        guard let json = ToolCardSemanticHelpers.parseJSON(raw) else { return nil }
        return firstStringValue(
            in: json,
            keys: ["file_path", "filePath", "path", "target", "uri"]
        )
    }

    private func extractPatternField(from raw: String?) -> String? {
        guard let raw else { return nil }
        guard let json = ToolCardSemanticHelpers.parseJSON(raw) else { return nil }
        return firstStringValue(
            in: json,
            keys: ["pattern", "glob", "query", "pathPattern", "path_pattern"]
        )
    }

    private func firstStringValue(in value: Any, keys: [String], maxDepth: Int = 6) -> String? {
        if maxDepth < 0 { return nil }

        if let dict = value as? [String: Any] {
            for key in keys {
                if let raw = dict[key] as? String {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
            for nested in dict.values {
                if let found = firstStringValue(in: nested, keys: keys, maxDepth: maxDepth - 1) {
                    return found
                }
            }
            return nil
        }

        if let list = value as? [Any] {
            for item in list {
                if let found = firstStringValue(in: item, keys: keys, maxDepth: maxDepth - 1) {
                    return found
                }
            }
            return nil
        }

        return nil
    }

    private func compacted(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
