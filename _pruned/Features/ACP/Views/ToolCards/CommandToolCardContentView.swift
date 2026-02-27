//
//  CommandToolCardContentView.swift
//  contextgo
//
//  Command-oriented tool card renderers.
//

import SwiftUI

struct CommandToolCardContentView: View {
    let context: ToolCardRenderContext
    let onOpenDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let commandText {
                DetailSection(
                    title: "命令",
                    icon: "terminal",
                    copyText: commandText
                ) {
                    CodeBlock(text: "$ \(commandText)")
                }
            } else {
                Text("协议未提供命令原文")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let parsed = ToolCardSemanticHelpers.parseBashInput(context.resolvedInput) {
                commandMeta(parsed)
            }

            if let output = context.resolvedOutput,
               !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DetailSection(
                    title: "输出",
                    icon: "arrow.up.circle",
                    copyText: commandOutputCopyText(from: output)
                ) {
                    commandOutput(output)
                }
            }

            if context.hasSidecarPayloadRef {
                Button(action: onOpenDetail) {
                    Label("查看完整命令详情", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var commandText: String? {
        CommandToolCardContentView.resolvedCommand(for: context)
    }

    @ViewBuilder
    private func commandMeta(_ parsed: ParsedBashInput) -> some View {
        HStack(spacing: 10) {
            if let cwd = parsed.cwd, !cwd.isEmpty {
                Label(cwd, systemImage: "folder")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let timeout = parsed.timeout, !timeout.isEmpty {
                Label(timeout, systemImage: "clock")
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)

        if let reason = parsed.reason, !reason.isEmpty {
            Text(reason)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func commandOutput(_ raw: String) -> some View {
        if let parsed = ToolCardSemanticHelpers.parseBashOutput(raw) {
            VStack(alignment: .leading, spacing: 6) {
                if let status = parsed.status, !status.isEmpty {
                    Label("状态 \(status)", systemImage: "circle.lefthalf.filled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let exitCode = parsed.exitCode, !exitCode.isEmpty {
                    Label("退出码 \(exitCode)", systemImage: "flag.checkered")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let processId = parsed.processId, !processId.isEmpty {
                    Label("进程 \(processId)", systemImage: "number.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let stdout = parsed.stdout, !stdout.isEmpty {
                    CodeBlock(text: stdout)
                }

                if let stderr = parsed.stderr, !stderr.isEmpty {
                    ErrorBlock(text: stderr)
                }
            }
        } else if context.toolUse.status == .error {
            ErrorBlock(text: raw)
        } else {
            CodeBlock(text: ToolCardSemanticHelpers.readableToolOutput(raw))
        }
    }

    private func commandOutputCopyText(from raw: String) -> String {
        guard let parsed = ToolCardSemanticHelpers.parseBashOutput(raw) else {
            return raw
        }
        if let stdout = parsed.stdout, !stdout.isEmpty {
            return stdout
        }
        if let stderr = parsed.stderr, !stderr.isEmpty {
            return stderr
        }
        return raw
    }
}

struct CommandToolCardDetailSheetView: View {
    let context: ToolCardRenderContext
    let loadState: ToolCardDetailLoadState
    let onClose: () -> Void
    @State private var showRawPayload = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loadState.isLoading {
                        ProgressView("加载中...")
                    }

                    if let error = loadState.errorMessage,
                       !error.isEmpty {
                        ErrorBlock(text: error)
                    }

                    if let commandText {
                        DetailSection(title: "命令", icon: "terminal", copyText: commandText) {
                            CodeBlock(text: "$ \(commandText)")
                        }
                    } else {
                        Text("协议未提供命令原文")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let output = context.resolvedOutput,
                       !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSection(title: "命令输出", icon: "arrow.up.circle", copyText: commandOutputCopyText(from: output)) {
                            commandOutput(output)
                        }
                    }

                    if hasRawPayload {
                        DisclosureGroup("原始 payload（调试）", isExpanded: $showRawPayload) {
                            VStack(alignment: .leading, spacing: 12) {
                                if let input = context.resolvedInput,
                                   !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    DetailSection(title: "输入 payload", icon: "arrow.down.circle", copyText: input) {
                                        CodeBlock(text: ToolCardSemanticHelpers.prettyPrintedJSONIfPossible(input))
                                    }
                                }

                                if let output = context.resolvedOutput,
                                   !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    DetailSection(title: "输出 payload", icon: "arrow.up.circle", copyText: output) {
                                        CodeBlock(text: ToolCardSemanticHelpers.prettyPrintedJSONIfPossible(output))
                                    }
                                }
                            }
                            .padding(.top, 6)
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)
                    }
                }
                .padding(16)
            }
            .navigationTitle("命令详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", action: onClose)
                }
            }
        }
    }

    private var commandText: String? {
        CommandToolCardContentView.resolvedCommand(for: context)
    }

    private var hasRawPayload: Bool {
        if let input = context.resolvedInput,
           !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return false
    }

    @ViewBuilder
    private func commandOutput(_ raw: String) -> some View {
        if let parsed = ToolCardSemanticHelpers.parseBashOutput(raw) {
            VStack(alignment: .leading, spacing: 6) {
                if let status = parsed.status, !status.isEmpty {
                    Label("状态 \(status)", systemImage: "circle.lefthalf.filled")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let exitCode = parsed.exitCode, !exitCode.isEmpty {
                    Label("退出码 \(exitCode)", systemImage: "flag.checkered")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let processId = parsed.processId, !processId.isEmpty {
                    Label("进程 \(processId)", systemImage: "number.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let stdout = parsed.stdout, !stdout.isEmpty {
                    CodeBlock(text: stdout)
                }

                if let stderr = parsed.stderr, !stderr.isEmpty {
                    ErrorBlock(text: stderr)
                }
            }
        } else if context.toolUse.status == .error {
            ErrorBlock(text: raw)
        } else {
            CodeBlock(text: ToolCardSemanticHelpers.readableToolOutput(raw))
        }
    }

    private func commandOutputCopyText(from raw: String) -> String {
        guard let parsed = ToolCardSemanticHelpers.parseBashOutput(raw) else {
            return raw
        }
        if let stdout = parsed.stdout, !stdout.isEmpty {
            return stdout
        }
        if let stderr = parsed.stderr, !stderr.isEmpty {
            return stderr
        }
        return raw
    }
}

extension CommandToolCardContentView {
    static func displayName(for context: ToolCardRenderContext) -> String {
        guard let command = resolvedCommand(for: context) else {
            return "命令执行"
        }

        switch ToolCardSemanticHelpers.classifyCommandSubtype(command) {
        case .search:
            return "文件搜索"
        case .read:
            return "文件读取"
        case .list:
            return "目录列举"
        case .generic:
            return "命令执行"
        }
    }

    static func iconName(for context: ToolCardRenderContext) -> String {
        guard let command = resolvedCommand(for: context) else {
            return "terminal"
        }

        switch ToolCardSemanticHelpers.classifyCommandSubtype(command) {
        case .search:
            return "magnifyingglass"
        case .read:
            return "doc.text"
        case .list:
            return "folder"
        case .generic:
            return "terminal"
        }
    }

    static func summaryText(for context: ToolCardRenderContext) -> String {
        if let command = resolvedCommand(for: context) {
            return "$ \(command)"
        }

        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let parsed = ToolCardSemanticHelpers.parseBashOutput(output) {
                if let exitCode = parsed.exitCode,
                   !exitCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "命令结果（exit \(exitCode)）"
                }
                if let status = parsed.status,
                   !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "命令结果（\(status)）"
                }
            }
            return "命令结果"
        }

        return "命令执行"
    }

    fileprivate static func resolvedCommand(for context: ToolCardRenderContext) -> String? {
        let candidates: [String?] = [
            ToolCardSemanticHelpers.parseBashInput(context.resolvedInput)?.command,
            ToolCardSemanticHelpers.extractCommand(from: context.resolvedInput),
            ToolCardSemanticHelpers.parseBashOutput(context.resolvedOutput)?.command
        ]

        for candidate in candidates {
            if let normalized = normalizeCommandCandidate(candidate, output: context.resolvedOutput) {
                return normalized
            }
        }
        return nil
    }

    private static func normalizeCommandCandidate(_ raw: String?, output: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if looksLikeDirectoryListingOutput(trimmed) {
            return nil
        }

        // Guard against path-only fallbacks being rendered as shell commands.
        if looksLikeBarePath(trimmed),
           let outputFirstLine = firstNonEmptyLine(in: output),
           outputFirstLine == trimmed {
            return nil
        }

        if let output = output?.trimmingCharacters(in: .whitespacesAndNewlines),
           !output.isEmpty,
           trimmed == output {
            return nil
        }

        return trimmed
    }

    private static func looksLikeBarePath(_ value: String) -> Bool {
        if value.contains(where: \.isNewline) {
            return false
        }

        let separators = CharacterSet.whitespacesAndNewlines
        if value.rangeOfCharacter(from: separators) != nil {
            return false
        }

        if value.contains("|")
            || value.contains("&")
            || value.contains(";")
            || value.contains("$")
            || value.contains(">")
            || value.contains("<") {
            return false
        }

        return value.hasPrefix("/")
            || value.hasPrefix("./")
            || value.hasPrefix("../")
            || value.hasPrefix("~/")
    }

    private static func firstNonEmptyLine(in text: String?) -> String? {
        guard let text else { return nil }
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty {
                return line
            }
        }
        return nil
    }

    private static func looksLikeDirectoryListingOutput(_ value: String) -> Bool {
        let lines = value
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return false }

        if lines.first?.lowercased().hasPrefix("total ") == true {
            return true
        }

        var permissionStyleLineCount = 0
        for line in lines.prefix(8) {
            guard let token = line.split(whereSeparator: \.isWhitespace).first else { continue }
            let fileMode = String(token)
            if fileMode.hasPrefix("drwx")
                || fileMode.hasPrefix("-rw")
                || fileMode.hasPrefix("lrw")
                || fileMode.hasPrefix("crw")
                || fileMode.hasPrefix("brw")
                || fileMode.hasPrefix("srw")
                || fileMode.hasPrefix("prw") {
                permissionStyleLineCount += 1
            }
        }

        return permissionStyleLineCount >= 2
    }
}
