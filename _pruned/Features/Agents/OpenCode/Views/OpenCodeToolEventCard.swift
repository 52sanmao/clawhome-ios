import SwiftUI

private enum OpenCodeToolDetailSheet: String, Identifiable {
    case raw
    case todo
    case task
    case command
    case skill
    case skillList
    case generic

    var id: String { rawValue }
}

struct OpenCodeToolEventCard: View {
    let toolUse: CLIMessage.ToolUse
    var isActionLoading: Bool = false
    var onAllow: ((String) -> Void)? = nil
    var onAllowForSession: ((String) -> Void)? = nil
    var onDeny: ((String) -> Void)? = nil

    @State private var activeSheet: OpenCodeToolDetailSheet?

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

    private var context: ToolCardRenderContext {
        ToolCardRenderContext(
            toolUse: toolUse,
            providerFlavor: "opencode",
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
            return CommandToolCardContentView.displayName(for: context)
        case .parallelDispatch:
            return "并行调度"
        case .read:
            return "文件读取"
        case .glob:
            return "文件搜索"
        case .fileEdit:
            return "文件编辑"
        case .todo:
            return "Todo"
        case .task:
            return "Task"
        case .backgroundTask:
            return "Background Task"
        case .sessionControl:
            return "会话控制"
        case .webSearch:
            return "Web Search"
        case .titleChange:
            return "标题更新"
        case .reasoning:
            return "Reasoning"
        case .protocolFallback:
            return "协议事件"
        case .generic:
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

    private var supportsDetailSheet: Bool {
        semanticKind != .titleChange
    }

    private var commandSubtype: CommandSubtype {
        guard semanticKind == .command,
              let command = resolvedCommand else {
            return .generic
        }
        return ToolCardSemanticHelpers.classifyCommandSubtype(command)
    }

    private var shouldRenderCompactCommandPreview: Bool {
        switch commandSubtype {
        case .read, .list:
            return true
        case .search, .generic:
            return false
        }
    }

    private var shouldUseSingleLinePreview: Bool {
        semanticKind == .read || shouldRenderCompactCommandPreview
    }

    private var resolvedCommand: String? {
        let candidates: [String?] = [
            ToolCardSemanticHelpers.parseBashInput(context.resolvedInput)?.command,
            ToolCardSemanticHelpers.extractCommand(from: context.resolvedInput),
            ToolCardSemanticHelpers.parseBashOutput(context.resolvedOutput)?.command
        ]

        for candidate in candidates {
            let normalized = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !normalized.isEmpty {
                return normalized
            }
        }
        return nil
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
            return CommandToolCardContentView.summaryText(for: context)
        case .glob:
            if let searchSummary = searchPreviewSummary(from: context.resolvedInput), !searchSummary.isEmpty {
                return searchSummary
            }
            return GenericToolCardContentView.summaryText(for: context)
        case .parallelDispatch:
            return ParallelDispatchToolCardContentView.summaryText(for: context)
        case .todo:
            return TodoToolCardContentView.summaryText(for: context)
        case .task:
            return TaskToolCardContentView.summaryText(for: context)
        case .backgroundTask:
            return OpenCodeBackgroundTaskToolCardContentView.summaryText(for: context)
        case .protocolFallback:
            return ProtocolFallbackToolCardContentView.summaryText(for: context)
        case .reasoning:
            return ReasoningToolCardContentView.summaryText(for: context)
        case .generic, .sessionControl, .webSearch, .read, .fileEdit, .titleChange:
            return GenericToolCardContentView.summaryText(for: context)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(iconColor)

                Text(displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                StatusBadge(status: toolUse.status)

                if supportsDetailSheet {
                    Button {
                        if isSkillGetTool {
                            activeSheet = .skill
                        } else if isSkillListTool {
                            activeSheet = .skillList
                        } else {
                            activeSheet = .raw
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

            toolCardBody
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
    private var toolCardBody: some View {
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
            switch semanticKind {
            case .todo:
                TodoToolCardContentView(context: context)
            case .backgroundTask:
                OpenCodeBackgroundTaskToolCardContentView(context: context)
            case .task:
                TaskToolCardContentView(context: context) {
                    activeSheet = .task
                }
            case .command:
                if shouldRenderCompactCommandPreview {
                    Text(previewText)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    CommandToolCardContentView(context: context) {
                        activeSheet = .command
                    }
                }
            default:
                Text(previewText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(shouldUseSingleLinePreview ? 1 : 2)
                    .truncationMode(.tail)
            }
        }
    }

    @ViewBuilder
    private func detailSheet(for sheet: OpenCodeToolDetailSheet) -> some View {
        switch sheet {
        case .raw:
            OpenCodeRawToolDetailSheet(
                toolUse: toolUse,
                semanticKind: semanticKind,
                isActionLoading: isActionLoading,
                onAllow: onAllow,
                onAllowForSession: onAllowForSession,
                onDeny: onDeny
            )
        case .skill:
            SkillGetToolDetailSheet(toolUse: toolUse)
        case .skillList:
            SkillListToolDetailSheet(toolUse: toolUse)
        case .todo:
            TodoToolCardDetailSheetView(
                context: context,
                loadState: ToolCardDetailLoadState(isLoading: false, errorMessage: nil),
                onClose: { activeSheet = nil }
            )
        case .task:
            TaskToolCardDetailSheetView(
                context: context,
                loadState: ToolCardDetailLoadState(isLoading: false, errorMessage: nil),
                onClose: { activeSheet = nil }
            )
        case .command:
            CommandToolCardDetailSheetView(
                context: context,
                loadState: ToolCardDetailLoadState(isLoading: false, errorMessage: nil),
                onClose: { activeSheet = nil }
            )
        case .generic:
            GenericToolCardDetailSheetView(
                context: context,
                loadState: ToolCardDetailLoadState(isLoading: false, errorMessage: nil),
                onClose: { activeSheet = nil }
            )
        }
    }

    private func compacted(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func searchPreviewSummary(from raw: String?) -> String? {
        guard let payload = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !payload.isEmpty else {
            return nil
        }
        guard let parsed = ToolUseJSONParser.parseJSON(payload) else { return nil }

        func firstString(in value: Any, keys: [String]) -> String? {
            if let dict = value as? [String: Any] {
                for key in keys {
                    if let text = dict[key] as? String {
                        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    }
                }
                for nestedKey in ["rawInput", "input", "payload", "data", "params", "arguments"] {
                    if let nested = dict[nestedKey],
                       let found = firstString(in: nested, keys: keys) {
                        return found
                    }
                }
            }
            if let list = value as? [Any] {
                for item in list {
                    if let found = firstString(in: item, keys: keys) {
                        return found
                    }
                }
            }
            return nil
        }

        let pattern = firstString(in: parsed, keys: ["pattern", "glob", "query"])
        let path = firstString(in: parsed, keys: ["path", "cwd", "root", "filePath"])

        if let pattern {
            return pattern
        }
        if let path {
            return path
        }
        return nil
    }
}

private struct OpenCodeRawToolDetailSheet: View {
    let toolUse: CLIMessage.ToolUse
    let semanticKind: CLIToolCardKind
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
        let inline = prettified(toolUse.output)
        if !inline.isEmpty {
            return inline
        }
        guard let ref = toolUse.outputPayloadRef else { return "" }
        return prettified(readToolPayloadSidecar(ref: ref))
    }

    private var sidecarPreview: String? {
        guard semanticKind == .glob || semanticKind == .read else { return nil }

        let candidate: String = {
            if let ref = toolUse.outputPayloadRef,
               let text = readToolPayloadSidecar(ref: ref),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            return toolUse.output ?? ""
        }()

        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let extracted = extractReadableContent(candidate)
        let lines = extracted
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        guard !lines.isEmpty else { return nil }
        return lines.prefix(10).map(String.init).joined(separator: "\n")
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

                                if permission.status == .pending {
                                    HStack(spacing: 10) {
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

                    if let sidecarPreview,
                       !sidecarPreview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSection(title: "读取预览（前10行）", icon: "doc.text.magnifyingglass", copyText: sidecarPreview) {
                            CodeBlock(text: sidecarPreview)
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
                }
                .padding(16)
            }
            .navigationTitle(displayName)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private extension OpenCodeRawToolDetailSheet {
    func prettified(_ raw: String?) -> String {
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

    func extractReadableContent(_ raw: String) -> String {
        if let parsed = ToolUseJSONParser.parseJSON(raw),
           let dict = parsed as? [String: Any] {
            if let preview = deepFirstString(in: dict, keys: ["preview"]),
               !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return preview
            }
            if let output = deepFirstString(in: dict, keys: ["output", "content", "text"]),
               !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return output
            }
        }
        return raw
    }

    func deepFirstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }

        for nestedKey in ["metadata", "rawOutput", "payload", "data", "result"] {
            if let nested = dict[nestedKey] as? [String: Any],
               let value = deepFirstString(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    func readToolPayloadSidecar(ref: String) -> String? {
        let trimmedRef = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRef.isEmpty else { return nil }

        let fileManager = FileManager.default
        let candidates: [URL] = {
            if trimmedRef.hasPrefix("/") {
                return [URL(fileURLWithPath: trimmedRef)]
            }

            guard let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
                return [URL(fileURLWithPath: trimmedRef)]
            }

            let sessionsRoot = docs.appendingPathComponent("sessions", isDirectory: true)
            var urls: [URL] = []
            urls.append(sessionsRoot.appendingPathComponent(trimmedRef))
            urls.append(docs.appendingPathComponent(trimmedRef))

            if trimmedRef.hasPrefix("sessions/") {
                let dropped = String(trimmedRef.dropFirst("sessions/".count))
                urls.append(sessionsRoot.appendingPathComponent(dropped))
                urls.append(docs.appendingPathComponent(dropped))
            }

            if let usersRange = trimmedRef.range(of: "users/") {
                let suffix = String(trimmedRef[usersRange.lowerBound...])
                urls.append(sessionsRoot.appendingPathComponent(suffix))
                urls.append(docs.appendingPathComponent(suffix))
            }

            return urls
        }()

        for url in candidates {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return nil
    }
}
