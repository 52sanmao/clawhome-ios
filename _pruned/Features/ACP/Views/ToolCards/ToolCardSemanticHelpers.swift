//
//  ToolCardSemanticHelpers.swift
//  contextgo
//
//  Lightweight semantic helpers for modular tool card renderers.
//

import Foundation

enum CommandSubtype {
    case search
    case read
    case list
    case generic
}

enum ToolCardSemanticHelpers {
    private static let regexCache = NSCache<NSString, NSRegularExpression>()
    private static let bashLooseFieldHints: [String] = [
        "\"stdout\"", "\"stderr\"", "\"output\"", "\"result\"",
        "\"aggregated_output\"", "\"aggregatedoutput\"",
        "\"formatted_output\"", "\"formattedoutput\"",
        "\"exit_code\"", "\"exitcode\"", "\"status\"", "\"state\"",
        "\"process_id\"", "\"processid\"", "\"pid\"",
        "\"command\"", "\"cmd\"", "\"script\"", "\"parsed_cmd\""
    ]

    static func parseJSON(_ raw: String?) -> Any? {
        guard let raw else { return nil }
        return ToolUseJSONParser.parseJSON(raw)
    }

    static func prettyPrintedJSONIfPossible(_ raw: String) -> String {
        ToolUseJSONParser.prettyPrintedJSONIfPossible(raw)
    }

    static func firstMeaningfulLine(from text: String, maxLength: Int = 140) -> String {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let line = lines.first(where: { !isLowSignalLine($0) })
            ?? lines.first
            ?? text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard line.count > maxLength else { return line }
        return String(line.prefix(maxLength - 3)) + "..."
    }

    static func readableToolOutput(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        if let parsed = parseBashOutput(trimmed) {
            var sections: [String] = []
            if let stdout = parsed.stdout, !stdout.isEmpty {
                sections.append(stdout)
            }
            if let stderr = parsed.stderr, !stderr.isEmpty {
                sections.append(stderr)
            }
            if sections.isEmpty {
                sections.append(trimmed)
            }
            return sections.joined(separator: "\n")
        }

        return trimmed
    }

    static func classifyCommandSubtype(_ command: String) -> CommandSubtype {
        let lowered = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.isEmpty {
            return .generic
        }

        if lowered.contains(" rg ")
            || lowered.hasPrefix("rg ")
            || lowered.contains(" grep ")
            || lowered.hasPrefix("grep ")
            || lowered.contains(" find ")
            || lowered.hasPrefix("find ")
            || lowered.contains(" fd ")
            || lowered.hasPrefix("fd ") {
            return .search
        }

        if lowered.hasPrefix("cat ")
            || lowered.contains(" sed -n ")
            || lowered.hasPrefix("sed -n ")
            || lowered.hasPrefix("nl -ba ")
            || lowered.contains(" head ")
            || lowered.hasPrefix("head ")
            || lowered.contains(" tail ")
            || lowered.hasPrefix("tail ")
            || lowered.hasPrefix("less ")
            || lowered.hasPrefix("bat ") {
            return .read
        }

        if lowered.hasPrefix("ls ")
            || lowered == "ls"
            || lowered.hasPrefix("tree ")
            || lowered == "tree" {
            return .list
        }

        return .generic
    }

    static func extractLikelyPathFromCommand(_ command: String) -> String? {
        let tokens = command
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            .filter { !$0.isEmpty }

        for token in tokens.reversed() {
            if token.hasPrefix("-") { continue }
            if token.contains("/")
                || token.hasSuffix(".swift")
                || token.hasSuffix(".ts")
                || token.hasSuffix(".md")
                || token.hasSuffix(".json") {
                return token
            }
        }
        return nil
    }

    static func extractCommand(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let parsed = parseBashInput(trimmed), !parsed.command.isEmpty {
            return sanitizeCommandCandidate(parsed.command)
        }

        if let json = ToolUseJSONParser.parseJSON(trimmed),
           let command = extractCommandFromJSON(json),
           !command.isEmpty {
            return sanitizeCommandCandidate(command)
        }

        let line = firstMeaningfulLine(from: trimmed)
        if line.hasPrefix("{") || line.hasPrefix("[") {
            return nil
        }
        return sanitizeCommandCandidate(line)
    }

    static func parseBashInput(_ raw: String?) -> ParsedBashInput? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let json = ToolUseJSONParser.parseJSON(trimmed),
           let dict = json as? [String: Any] {
            let command = extractCommandFromBashPayload(dict)

            guard let command, !command.isEmpty else { return nil }

            let cwd = firstString(in: dict, keys: ["cwd", "working_dir", "workingDir"])
            let reason = firstString(in: dict, keys: ["reason", "description", "purpose"])
            let timeout = firstString(in: dict, keys: ["timeout", "timeoutMs", "timeout_ms"])
            return ParsedBashInput(command: command, cwd: cwd, reason: reason, timeout: timeout)
        }

        // Avoid treating serialized tool-result payloads as commands.
        if looksLikeToolResultPayload(trimmed) {
            return nil
        }

        return ParsedBashInput(command: trimmed, cwd: nil, reason: nil, timeout: nil)
    }

    static func parseBashOutput(_ raw: String?) -> ParsedBashOutput? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let json = ToolUseJSONParser.parseJSON(trimmed) {
            let stdout = extractStringValue(
                in: json,
                keys: [
                    "stdout", "output", "result", "aggregated_output", "aggregatedOutput",
                    "formatted_output", "formattedOutput", "content", "text", "response"
                ]
            )
            let stderr = extractStringValue(
                in: json,
                keys: ["stderr", "error", "error_message", "errorMessage"]
            )
            let exitCode = extractStringValue(
                in: json,
                keys: ["exitCode", "exit_code", "code", "statusCode"]
            )
            let status = extractStringValue(
                in: json,
                keys: ["status", "state", "resultStatus"]
            )
            let processId = extractStringValue(
                in: json,
                keys: ["processId", "process_id", "pid"]
            )
            let command: String? = {
                if let dict = json as? [String: Any] {
                    return extractCommandFromBashPayload(dict)
                }
                if let list = json as? [Any] {
                    return extractCommandValue(list)
                }
                return nil
            }()

            if stdout != nil || stderr != nil || exitCode != nil || status != nil || processId != nil || command != nil {
                return ParsedBashOutput(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: exitCode,
                    status: status,
                    processId: processId,
                    command: command
                )
            }
        }

        // Protocol-first parsing: if payload is not structured JSON, treat it as plain output.
        return ParsedBashOutput(
            stdout: trimmed,
            stderr: nil,
            exitCode: nil,
            status: nil,
            processId: nil,
            command: nil
        )
    }

    static func parseReadOutput(_ raw: String?) -> ParsedReadOutput? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let json = ToolUseJSONParser.parseJSON(trimmed),
           let dict = json as? [String: Any] {
            let path = firstString(in: dict, keys: ["path", "filePath", "file_path"])
            let type = firstString(in: dict, keys: ["type", "kind", "nodeType", "node_type"])
            let content = firstString(in: dict, keys: ["content", "output", "result"])
            let entriesBlock: String? = {
                if let entries = dict["entries"] as? [Any] {
                    let lines = entries.compactMap { valueAsString($0) }
                        .filter { !$0.isEmpty }
                    return lines.isEmpty ? nil : lines.joined(separator: "\n")
                }
                if let text = valueAsString(dict["entries"]) {
                    return text.isEmpty ? nil : text
                }
                return nil
            }()

            if path != nil || type != nil || content != nil || entriesBlock != nil {
                return ParsedReadOutput(
                    path: path,
                    type: type,
                    content: content,
                    entriesBlock: entriesBlock
                )
            }
        }

        let path = extractTaggedContent(tag: "path", from: trimmed)
        let type = extractTaggedContent(tag: "type", from: trimmed)
        let content = extractTaggedContent(tag: "content", from: trimmed)
        let entriesBlock = extractTaggedContent(tag: "entries", from: trimmed)

        if path == nil, type == nil, content == nil, entriesBlock == nil {
            return nil
        }

        return ParsedReadOutput(
            path: path,
            type: type,
            content: content,
            entriesBlock: entriesBlock
        )
    }

    static func summarizeReadPayload(from raw: String?) -> String? {
        guard let parsed = parseReadOutput(raw) else { return nil }

        let path = parsed.path?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedType = parsed.type?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let totalEntries = entryCount(from: parsed.entriesBlock)
        let looksLikeDirectory = normalizedType == "directory" || parsed.entriesBlock != nil
        let looksLikeFile = normalizedType == "file" || parsed.content != nil

        if looksLikeDirectory {
            if let path {
                if let totalEntries {
                    return "\(path) (\(totalEntries) entries)"
                }
                return path
            }
            if let totalEntries {
                return "directory (\(totalEntries) entries)"
            }
            return "directory"
        }

        if looksLikeFile {
            if let path, !path.isEmpty {
                return path
            }
            return "file"
        }

        if let path, !path.isEmpty {
            return path
        }

        if let content = parsed.content,
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return firstMeaningfulLine(from: content)
        }

        return nil
    }

    static func parseTaskInput(_ raw: String?) -> ParsedTaskInput? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let json = ToolUseJSONParser.parseJSON(trimmed),
           let dict = json as? [String: Any] {
            let subagentType = firstString(in: dict, keys: ["subagent_type", "subagentType", "agent", "type"]) ?? "task"
            let description = firstString(in: dict, keys: ["description", "task", "summary"])
            let prompt = firstString(in: dict, keys: ["prompt", "instruction", "input"]) ?? nestedString(in: dict, path: ["input", "prompt"])
            return ParsedTaskInput(subagentType: subagentType, description: description, prompt: prompt)
        }

        return ParsedTaskInput(subagentType: "task", description: firstMeaningfulLine(from: trimmed), prompt: nil)
    }

    static func parseBackgroundTaskInput(_ raw: String?) -> ParsedBackgroundTaskInput? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let json = ToolUseJSONParser.parseJSON(trimmed),
           let dict = json as? [String: Any] {
            let taskId = firstString(in: dict, keys: ["task_id", "taskId", "id"])
            let state = firstString(in: dict, keys: ["state", "status"])
            let title = firstString(in: dict, keys: ["title", "name"])
            let detail = firstString(in: dict, keys: ["detail", "description", "message"])
            let extraPayload: String? = {
                var payload = dict
                payload.removeValue(forKey: "task_id")
                payload.removeValue(forKey: "taskId")
                payload.removeValue(forKey: "id")
                payload.removeValue(forKey: "state")
                payload.removeValue(forKey: "status")
                payload.removeValue(forKey: "title")
                payload.removeValue(forKey: "name")
                payload.removeValue(forKey: "detail")
                payload.removeValue(forKey: "description")
                payload.removeValue(forKey: "message")
                guard !payload.isEmpty,
                      let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
                      let text = String(data: data, encoding: .utf8) else {
                    return nil
                }
                return text
            }()

            return ParsedBackgroundTaskInput(
                taskId: taskId,
                state: state,
                title: title,
                detail: detail,
                extraPayload: extraPayload,
                isMinimal: extraPayload == nil
            )
        }

        return ParsedBackgroundTaskInput(
            taskId: nil,
            state: nil,
            title: nil,
            detail: firstMeaningfulLine(from: trimmed),
            extraPayload: nil,
            isMinimal: true
        )
    }

    static func parseParallelDispatchOperations(_ raw: String?) -> [ParallelDispatchOperationSnapshot] {
        guard let raw,
              let json = ToolUseJSONParser.parseJSON(raw),
              let dict = json as? [String: Any] else {
            return []
        }

        if let operations = dict["operations"] as? [[String: Any]], !operations.isEmpty {
            return operations.enumerated().compactMap { index, item in
                snapshotFromParallelOperation(item: item, index: index)
            }
        }

        if let parsed = extractParsedCommandOperations(from: dict),
           !parsed.isEmpty {
            return parsed.enumerated().compactMap { index, item in
                snapshotFromParallelOperation(item: item, index: index)
            }
        }

        let toolUses: [Any]? = {
            if let value = dict["tool_uses"] as? [Any] { return value }
            if let value = dict["toolUses"] as? [Any] { return value }
            if let value = dict["tools"] as? [Any] { return value }
            return nil
        }()

        guard let toolUses else { return [] }

        return toolUses.enumerated().compactMap { index, value in
            guard let item = value as? [String: Any] else { return nil }

            let recipientRaw = (item["recipient_name"] as? String)
                ?? (item["recipientName"] as? String)
                ?? (item["tool"] as? String)
                ?? (item["name"] as? String)
                ?? ""
            let recipient = recipientRaw.replacingOccurrences(of: "functions.", with: "")
            let params = (item["parameters"] as? [String: Any])
                ?? (item["params"] as? [String: Any])
                ?? (item["input"] as? [String: Any])
                ?? [:]

            if recipient.contains("exec_command") {
                let command = (params["cmd"] as? String)
                    ?? (params["command"] as? String)
                    ?? ""
                let subtype = classifyCommandSubtype(command)
                switch subtype {
                case .search:
                    return ParallelDispatchOperationSnapshot(
                        id: "parallel-op-\(index)",
                        title: "Search",
                        detail: firstMeaningfulLine(from: command),
                        icon: "magnifyingglass"
                    )
                case .read:
                    return ParallelDispatchOperationSnapshot(
                        id: "parallel-op-\(index)",
                        title: "Read",
                        detail: extractLikelyPathFromCommand(command) ?? firstMeaningfulLine(from: command),
                        icon: "doc.text"
                    )
                case .list:
                    return ParallelDispatchOperationSnapshot(
                        id: "parallel-op-\(index)",
                        title: "List",
                        detail: extractLikelyPathFromCommand(command) ?? firstMeaningfulLine(from: command),
                        icon: "folder"
                    )
                case .generic:
                    return ParallelDispatchOperationSnapshot(
                        id: "parallel-op-\(index)",
                        title: "Command",
                        detail: firstMeaningfulLine(from: command),
                        icon: "terminal"
                    )
                }
            }

            let loweredRecipient = recipient.lowercased()
            if loweredRecipient.contains("read") {
                let path = (params["path"] as? String)
                    ?? (params["file_path"] as? String)
                    ?? (params["filePath"] as? String)
                return ParallelDispatchOperationSnapshot(
                    id: "parallel-op-\(index)",
                    title: "Read",
                    detail: path,
                    icon: "doc.text"
                )
            }

            if loweredRecipient.contains("search")
                || loweredRecipient.contains("grep")
                || loweredRecipient.contains("find") {
                return ParallelDispatchOperationSnapshot(
                    id: "parallel-op-\(index)",
                    title: "Search",
                    detail: firstMeaningfulLine(from: stringifyValue(params)),
                    icon: "magnifyingglass"
                )
            }

            return ParallelDispatchOperationSnapshot(
                id: "parallel-op-\(index)",
                title: recipient.isEmpty ? "Tool" : recipient,
                detail: nil,
                icon: "wrench.and.screwdriver"
            )
        }
    }

    private static func extractParsedCommandOperations(from dict: [String: Any]) -> [[String: Any]]? {
        let keys = ["parsed_cmd", "parsedCmd", "commandActions", "command_actions", "actions"]
        for key in keys {
            if let list = dict[key] as? [[String: Any]], !list.isEmpty {
                return list
            }
        }

        for containerKey in ["input", "payload", "data", "params", "parameters"] {
            guard let nested = dict[containerKey] as? [String: Any] else { continue }
            for key in keys {
                if let list = nested[key] as? [[String: Any]], !list.isEmpty {
                    return list
                }
            }
        }

        return nil
    }

    private static func snapshotFromParallelOperation(
        item: [String: Any],
        index: Int
    ) -> ParallelDispatchOperationSnapshot? {
        let type = ((item["type"] as? String) ?? (item["kind"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        let cmd = (item["cmd"] as? String) ?? (item["command"] as? String) ?? ""
        let path = (item["path"] as? String)
        let name = (item["name"] as? String)
        let query = (item["query"] as? String) ?? (item["pattern"] as? String)

        switch type {
        case "read":
            return ParallelDispatchOperationSnapshot(
                id: "parallel-op-\(index)",
                title: "Read",
                detail: path ?? name ?? firstMeaningfulLine(from: cmd),
                icon: "doc.text"
            )
        case "list_files", "list", "listfiles":
            return ParallelDispatchOperationSnapshot(
                id: "parallel-op-\(index)",
                title: "List",
                detail: path ?? firstMeaningfulLine(from: cmd),
                icon: "folder"
            )
        case "search", "grep", "find":
            let detail: String = {
                if let query, !query.isEmpty, let path, !path.isEmpty {
                    return "\(query) in \(path)"
                }
                if let query, !query.isEmpty {
                    return query
                }
                return firstMeaningfulLine(from: cmd)
            }()
            return ParallelDispatchOperationSnapshot(
                id: "parallel-op-\(index)",
                title: "Search",
                detail: detail,
                icon: "magnifyingglass"
            )
        default:
            if !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ParallelDispatchOperationSnapshot(
                    id: "parallel-op-\(index)",
                    title: "Run",
                    detail: firstMeaningfulLine(from: cmd),
                    icon: "terminal"
                )
            }
            if let path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ParallelDispatchOperationSnapshot(
                    id: "parallel-op-\(index)",
                    title: "Run",
                    detail: path,
                    icon: "terminal"
                )
            }
            return nil
        }
    }

    static func extractChangedTitle(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let json = ToolUseJSONParser.parseJSON(trimmed),
           let title = extractTitleFromJSON(json),
           !title.isEmpty {
            return title
        }

        let patterns = [
            #"Successfully changed chat title to:\s*\"([^\"]+)\""#,
            #"(?i)(?:set|rename(?:d)?|change(?:d)?|update(?:d)?)\s+(?:the\s+)?(?:chat\s+|session\s+)?title(?:\s+to)?\s*[\"“']([^\"”'\n]+)"#,
            #"(?i)标题(?:已)?(?:更新|修改|变更)(?:为|成)?\s*[:：]?\s*[\"“]?([^\"”\n]+)"#
        ]

        for pattern in patterns {
            guard let regex = cachedRegex(pattern: pattern, options: []) else { continue }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: trimmed) else {
                continue
            }
            let value = String(trimmed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }

        return nil
    }

    static func backgroundTaskStateLabel(from state: String?) -> String? {
        guard let state = state?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !state.isEmpty else {
            return nil
        }

        switch state {
        case "running", "in_progress", "active":
            return "进行中"
        case "success", "completed", "done":
            return "已完成"
        case "error", "failed", "cancelled", "canceled":
            return "失败"
        case "pending", "queued":
            return "排队中"
        default:
            return state
        }
    }

    static func todoProgressSummary(from items: [TodoItemSnapshot]) -> String? {
        guard !items.isEmpty else { return nil }

        let completed = items.filter { ToolUseTodoParser.normalizedStatus($0.status) == "completed" }.count
        let inProgress = items.filter { ToolUseTodoParser.normalizedStatus($0.status) == "in_progress" }.count
        let pending = items.filter { ToolUseTodoParser.normalizedStatus($0.status) == "pending" }.count

        guard completed + inProgress + pending > 0 else { return nil }
        return "Todo: \(items.count) 项（进行中 \(inProgress) / 待办 \(pending) / 已完成 \(completed)）"
    }

    private static func isLowSignalLine(_ line: String) -> Bool {
        let lowered = line.lowercased()
        if lowered == "```" || lowered == "```json" || lowered == "```jsonc" {
            return true
        }
        return line.range(of: #"^[\[\]\{\},]+$"#, options: .regularExpression) != nil
    }

    private static func sanitizeCommandCandidate(_ command: String?) -> String? {
        guard let command else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !looksLikeToolResultPayload(trimmed) else { return nil }

        if trimmed.hasPrefix("$ ") {
            return String(trimmed.dropFirst(2))
        }
        if trimmed.hasPrefix("$") {
            return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private static func extractCommandFromJSON(_ value: Any) -> String? {
        if let dict = value as? [String: Any] {
            if let command = firstString(in: dict, keys: ["command", "cmd", "script", "shell_command", "shellCommand"]) {
                return command
            }
            // Traverse only structural input containers; do not read result/output content as commands.
            for key in ["input", "params", "arguments", "payload", "data", "toolInput", "rawInput"] {
                if let nested = dict[key],
                   let command = extractCommandFromJSON(nested) {
                    return command
                }
            }
        }

        if let array = value as? [Any] {
            for item in array {
                if let command = extractCommandFromJSON(item) {
                    return command
                }
            }
        }

        if let string = value as? String {
            return string
        }

        return nil
    }

    private static func looksLikeToolResultPayload(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        let hasResultSignals = lowered.contains("\"status\"")
            || lowered.contains("\"stdout\"")
            || lowered.contains("\"stderr\"")
            || lowered.contains("\"output\"")
            || lowered.contains("\"result\"")
            || lowered.contains("\"exitcode\"")
            || lowered.contains("\"exit_code\"")
            || lowered.contains("\"aggregatedoutput\"")
            || lowered.contains("\"aggregated_output\"")

        let hasCommandSignals = lowered.contains("\"command\"")
            || lowered.contains("\"cmd\"")
            || lowered.contains("\"script\"")
            || lowered.contains("\"parsed_cmd\"")
            || lowered.contains(" /bin/")
            || lowered.contains(" bash ")
            || lowered.contains(" zsh ")
            || lowered.contains(" sh -")

        if hasResultSignals && !hasCommandSignals {
            return true
        }

        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")) && !hasCommandSignals {
            if lowered.contains("payload trimmed") && hasResultSignals {
                return true
            }
        }

        return false
    }

    private static func extractTitleFromJSON(_ value: Any) -> String? {
        var queue: [Any] = [value]
        var cursor = 0
        var scanned = 0

        while cursor < queue.count && scanned < 2048 {
            let current = queue[cursor]
            cursor += 1
            scanned += 1

            if let dict = current as? [String: Any] {
                for key in ["title", "new_title", "newTitle", "session_title", "chat_title", "updated_title", "renamed_to"] {
                    if let title = firstString(in: dict, keys: [key]), !title.isEmpty {
                        return title
                    }
                }
                dict.values.forEach { queue.append($0) }
                continue
            }

            if let array = current as? [Any] {
                array.forEach { queue.append($0) }
            }
        }

        return nil
    }

    private static func extractCommandFromBashPayload(_ dict: [String: Any]) -> String? {
        if let parsed = extractCommandFromParsedCommandList(
            dict["parsed_cmd"]
                ?? dict["parsedCmd"]
                ?? dict["command_actions"]
                ?? dict["commandActions"]
                ?? dict["actions"]
        ) {
            return sanitizeCommandCandidate(parsed)
        }

        if let direct = extractCommandValue(
            dict["command"]
                ?? dict["cmd"]
                ?? dict["script"]
                ?? dict["shell_command"]
                ?? dict["shellCommand"]
                ?? dict["command_line"]
                ?? dict["commandLine"]
        ) {
            return sanitizeCommandCandidate(direct)
        }

        for key in ["input", "params", "payload", "request", "arguments", "parameters", "data"] {
            guard let nested = dict[key] as? [String: Any],
                  let command = extractCommandFromBashPayload(nested) else {
                continue
            }
            return sanitizeCommandCandidate(command)
        }

        return nil
    }

    private static func extractCommandFromParsedCommandList(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let list = value as? [[String: Any]] {
            let commands = list.compactMap { item in
                extractCommandValue(item["cmd"] ?? item["command"] ?? item["script"])
            }
            let joined = commands
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " && ")
            return joined.isEmpty ? nil : joined
        }

        if let list = value as? [Any] {
            let commands = list.compactMap { extractCommandValue($0) }
            let joined = commands
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " && ")
            return joined.isEmpty ? nil : joined
        }

        if let dict = value as? [String: Any] {
            return extractCommandValue(dict["cmd"] ?? dict["command"] ?? dict["script"])
        }

        return extractCommandValue(value)
    }

    private static func extractCommandValue(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let number = value as? NSNumber {
            return number.stringValue
        }

        if let list = value as? [Any] {
            let tokens = list.compactMap { element -> String? in
                if let text = element as? String {
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                if let number = element as? NSNumber {
                    return number.stringValue
                }
                return extractCommandValue(element)
            }
            guard !tokens.isEmpty else { return nil }
            if let shellUnwrapped = extractCommandFromShellInvocation(tokens) {
                return shellUnwrapped
            }
            return tokens.joined(separator: " ")
        }

        if let dict = value as? [String: Any] {
            if let parsed = extractCommandFromParsedCommandList(
                dict["parsed_cmd"] ?? dict["parsedCmd"] ?? dict["actions"]
            ) {
                return parsed
            }

            if let direct = extractCommandValue(
                dict["command"] ?? dict["cmd"] ?? dict["script"] ?? dict["text"] ?? dict["value"]
            ) {
                return direct
            }

            if let executable = extractCommandValue(dict["executable"] ?? dict["program"] ?? dict["binary"]) {
                let args = extractCommandValue(dict["args"] ?? dict["arguments"])
                if let args, !args.isEmpty {
                    return "\(executable) \(args)"
                }
                return executable
            }

            for key in ["input", "params", "payload", "request", "arguments", "parameters", "data"] {
                if let nested = dict[key],
                   let command = extractCommandValue(nested) {
                    return command
                }
            }
        }

        return nil
    }

    private static func extractCommandFromShellInvocation(_ tokens: [String]) -> String? {
        guard !tokens.isEmpty else { return nil }
        guard tokens.count >= 3 else { return nil }
        guard isShellLauncherToken(tokens[0]) else { return nil }

        for flag in ["-lc", "-c", "/c", "-command", "-Command"] {
            if let flagIndex = tokens.firstIndex(where: { $0 == flag }),
               flagIndex + 1 < tokens.count {
                let commandTokens = tokens[(flagIndex + 1)...]
                let command = commandTokens
                    .joined(separator: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !command.isEmpty {
                    return command
                }
            }
        }

        return nil
    }

    private static func isShellLauncherToken(_ token: String) -> Bool {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let leaf = URL(fileURLWithPath: trimmed).lastPathComponent.lowercased()
        return leaf == "sh"
            || leaf == "bash"
            || leaf == "zsh"
            || leaf == "fish"
            || leaf == "pwsh"
            || leaf == "powershell"
            || leaf == "cmd.exe"
    }

    private static func extractTaggedContent(tag: String, from text: String) -> String? {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = "<\(escapedTag)>\\s*([\\s\\S]*?)\\s*</\(escapedTag)>"
        guard let regex = cachedRegex(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else {
            return nil
        }

        let value = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func entryCount(from entriesBlock: String?) -> Int? {
        guard let entriesBlock else { return nil }
        let trimmed = entriesBlock.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let patterns = [
            #"(?i)\(\s*showing\s+\d+\s+of\s+(\d+)\s+entries"#,
            #"(?i)\(\s*(\d+)\s+entries\)"#
        ]

        for pattern in patterns {
            guard let regex = cachedRegex(pattern: pattern, options: []) else { continue }
            let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: trimmed),
                  let count = Int(trimmed[range]) else {
                continue
            }
            return count
        }

        let entries = trimmed
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                guard !line.isEmpty else { return false }
                let lowered = line.lowercased()
                if lowered.hasPrefix("(showing ") && lowered.contains(" entries") {
                    return false
                }
                if line.range(of: #"^\(\d+\s+entries\)$"#, options: .regularExpression) != nil {
                    return false
                }
                return true
            }

        return entries.isEmpty ? nil : entries.count
    }

    private static func extractStringValue(in value: Any, keys: [String]) -> String? {
        var queue: [Any] = [value]
        var cursor = 0
        var scanned = 0
        let normalizedKeys = Set(keys.map { $0.lowercased() })

        while cursor < queue.count && scanned < 2048 {
            let current = queue[cursor]
            cursor += 1
            scanned += 1

            if let dict = current as? [String: Any] {
                for (key, candidate) in dict {
                    if normalizedKeys.contains(key.lowercased()),
                       let text = valueAsString(candidate),
                       !text.isEmpty {
                        return text
                    }
                }
                dict.values.forEach { queue.append($0) }
                continue
            }

            if let array = current as? [Any] {
                queue.append(contentsOf: array)
            }
        }

        return nil
    }

    private static func extractJSONStringField(in text: String, keys: [String]) -> String? {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = #"\"# + escaped + #"\"\s*:\s*\"((?:\\.|[^\"\\])*)(?:\"|$)"#
            guard let regex = cachedRegex(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
                  match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: text) else {
                continue
            }
            let fragment = String(text[range])
            let decoded = decodeEscapedJSONStringFragment(fragment)
            if !decoded.isEmpty {
                return decoded
            }
        }
        return nil
    }

    private static func decodeEscapedJSONStringFragment(_ raw: String) -> String {
        var fragment = raw
            .replacingOccurrences(of: #"\r"#, with: "\r")
            .replacingOccurrences(of: #"\n"#, with: "\n")
            .replacingOccurrences(of: #"\t"#, with: "\t")
            .replacingOccurrences(of: #"\""#, with: "\"")
            .replacingOccurrences(of: #"\/"#, with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let markerRange = fragment.range(of: "\n…[payload trimmed ") {
            fragment = String(fragment[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let markerRange = fragment.range(of: "…[payload trimmed ") {
            fragment = String(fragment[..<markerRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return fragment
    }

    private static func extractLooseScalarField(in text: String, keys: [String]) -> String? {
        for key in keys {
            let escaped = NSRegularExpression.escapedPattern(for: key)
            let pattern = #"\"# + escaped + #"\"\s*:\s*(null|true|false|-?\d+(?:\.\d+)?|\"((?:\\.|[^\"\\])*)\")"#
            guard let regex = cachedRegex(pattern: pattern, options: [.caseInsensitive]) else {
                continue
            }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: nsRange) else {
                continue
            }

            if match.numberOfRanges > 2,
               let quotedRange = Range(match.range(at: 2), in: text) {
                let quoted = decodeEscapedJSONStringFragment(String(text[quotedRange]))
                if !quoted.isEmpty && quoted.lowercased() != "null" {
                    return quoted
                }
            }

            if match.numberOfRanges > 1,
               let scalarRange = Range(match.range(at: 1), in: text) {
                let scalar = String(text[scalarRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !scalar.isEmpty && scalar.lowercased() != "null" {
                    return scalar
                }
            }
        }
        return nil
    }

    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key],
               let text = valueAsString(value),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func nestedString(in dict: [String: Any], path: [String]) -> String? {
        guard !path.isEmpty else { return nil }

        var current: Any = dict
        for key in path {
            guard let map = current as? [String: Any], let next = map[key] else {
                return nil
            }
            current = next
        }

        return valueAsString(current)
    }

    private static func valueAsString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let text = value as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let array = value as? [Any] {
            let merged = array.map { String(describing: $0) }.joined(separator: " ")
            return merged.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(describing: value)
    }

    private static func shouldAttemptLooseJSONFieldExtraction(in text: String) -> Bool {
        let lowered = text.lowercased()
        if bashLooseFieldHints.contains(where: { lowered.contains($0) }) {
            return true
        }

        if (lowered.hasPrefix("{") || lowered.hasPrefix("[")) && lowered.contains(":") {
            return true
        }

        return false
    }

    private static func cachedRegex(
        pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression? {
        let cacheKey = "\(options.rawValue)|\(pattern)" as NSString
        if let cached = regexCache.object(forKey: cacheKey) {
            return cached
        }

        guard let compiled = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil
        }
        regexCache.setObject(compiled, forKey: cacheKey)
        return compiled
    }

    private static func stringifyValue(_ value: Any) -> String {
        if let text = value as? String {
            return text
        }

        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
           let json = String(data: data, encoding: .utf8) {
            return json
        }

        return String(describing: value)
    }
}

struct SkillGetCardSnapshot {
    let skillUri: String?
    let skillName: String?
    let descriptionPreview: String?
    let hasSidecarPayload: Bool
}

struct SkillListCardSnapshot {
    let totalCount: Int
    let previewNames: [String]
    let previewUris: [String]
    let hasSidecarPayload: Bool
}

struct SkillListCardEntry: Identifiable, Hashable {
    let id: String
    let skillUri: String?
    let skillName: String
    let description: String?
}

struct SkillListCardDetail {
    let entries: [SkillListCardEntry]
    let totalCount: Int
    let sidecarRef: String?
    let loadedFromSidecar: Bool
}

struct SkillCreateCardSnapshot {
    let skillUri: String?
    let skillName: String?
    let descriptionPreview: String?
    let overwritten: Bool
}

struct SkillDeleteCardSnapshot {
    let skillUri: String?
    let skillName: String?
}

struct SkillGetCardDetail {
    let skillUri: String?
    let skillName: String?
    let description: String?
    let promptTemplate: String?
    let sidecarRef: String?
    let loadedFromSidecar: Bool

    var hasRenderableContent: Bool {
        let uri = skillUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = skillName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let desc = description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let prompt = promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !uri.isEmpty || !name.isEmpty || !desc.isEmpty || !prompt.isEmpty
    }
}

extension ToolCardSemanticHelpers {
    private struct SkillPayloadAccumulator {
        var skillUri: String?
        var skillName: String?
        var description: String?
        var promptTemplate: String?
    }

    private struct SkillListAccumulator {
        var explicitCount: Int?
        var names: [String] = []
        var uris: [String] = []
        var entries: [SkillListCardEntry] = []
    }

    static func isSkillGetToolName(_ name: String?) -> Bool {
        let key = (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty else { return false }

        if key == "skill_get" || key == "skill-get" || key == "skill.get" || key == "skillget" {
            return true
        }

        return CLIToolSemantics.hasToken("skill", in: key) && CLIToolSemantics.hasToken("get", in: key)
    }

    static func isSkillListToolName(_ name: String?) -> Bool {
        let key = (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty else { return false }

        if key == "skill_list" || key == "skill-list" || key == "skill.list" || key == "skilllist" {
            return true
        }

        return CLIToolSemantics.hasToken("skill", in: key) && CLIToolSemantics.hasToken("list", in: key)
    }

    static func isSkillCreateToolName(_ name: String?) -> Bool {
        let key = (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty else { return false }

        if key == "skill_create" || key == "skill-create" || key == "skill.create" || key == "skillcreate" {
            return true
        }

        return CLIToolSemantics.hasToken("skill", in: key) && CLIToolSemantics.hasToken("create", in: key)
    }

    static func isSkillDeleteToolName(_ name: String?) -> Bool {
        let key = (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !key.isEmpty else { return false }

        if key == "skill_delete" || key == "skill-delete" || key == "skill.delete" || key == "skilldelete" {
            return true
        }

        return CLIToolSemantics.hasToken("skill", in: key) && CLIToolSemantics.hasToken("delete", in: key)
    }

    static func skillGetPreviewSnapshot(for tool: CLIMessage.ToolUse) -> SkillGetCardSnapshot? {
        guard isSkillGetToolName(tool.name) else { return nil }

        var payload = parseSkillPayload(
            output: tool.output,
            input: tool.input,
            description: tool.description
        )
        enrichSkillPayloadFromSidecarIfNeeded(&payload, tool: tool)

        let preview = payload.description
            ?? payload.promptTemplate.map { firstMeaningfulLine(from: $0, maxLength: 180) }

        let outputRef = tool.outputPayloadRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inputRef = tool.inputPayloadRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasSidecar = !outputRef.isEmpty || !inputRef.isEmpty

        return SkillGetCardSnapshot(
            skillUri: payload.skillUri,
            skillName: payload.skillName,
            descriptionPreview: preview,
            hasSidecarPayload: hasSidecar
        )
    }

    static func loadSkillGetDetail(for tool: CLIMessage.ToolUse) -> SkillGetCardDetail? {
        guard isSkillGetToolName(tool.name) else { return nil }

        var payload = parseSkillPayload(
            output: tool.output,
            input: tool.input,
            description: tool.description
        )
        var loadedFromSidecar = false
        var usedSidecarRef: String?

        if payload.promptTemplate == nil || payload.description == nil || payload.skillUri == nil {
            let refs = [tool.outputPayloadRef, tool.inputPayloadRef]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for ref in refs {
                guard let sidecar = readToolPayloadSidecar(ref: ref),
                      !sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                let sidecarPayload = parseSkillPayload(output: sidecar, input: nil, description: nil)
                mergeSkillPayload(into: &payload, with: sidecarPayload)

                if payload.promptTemplate != nil || payload.description != nil || payload.skillUri != nil {
                    loadedFromSidecar = true
                    usedSidecarRef = ref
                    break
                }
            }
        }

        let detail = SkillGetCardDetail(
            skillUri: payload.skillUri,
            skillName: payload.skillName,
            description: payload.description,
            promptTemplate: payload.promptTemplate,
            sidecarRef: usedSidecarRef,
            loadedFromSidecar: loadedFromSidecar
        )

        return detail.hasRenderableContent ? detail : nil
    }

    static func skillListPreviewSnapshot(for tool: CLIMessage.ToolUse) -> SkillListCardSnapshot? {
        guard isSkillListToolName(tool.name) else { return nil }

        var accumulator = SkillListAccumulator()
        let ordered = [tool.output, tool.input, tool.description]
        for item in ordered {
            mergeSkillListPayload(from: item, into: &accumulator)
        }
        enrichSkillListFromSidecarIfNeeded(&accumulator, tool: tool)

        var uniqueNames: [String] = []
        for name in accumulator.names {
            let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty { continue }
            if !uniqueNames.contains(normalized) {
                uniqueNames.append(normalized)
            }
        }

        var uniqueUris: [String] = []
        for uri in accumulator.uris {
            let normalized = uri.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty { continue }
            if !uniqueUris.contains(normalized) {
                uniqueUris.append(normalized)
            }
        }

        let total = max(accumulator.explicitCount ?? 0, uniqueNames.count, uniqueUris.count)
        let outputRef = tool.outputPayloadRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let inputRef = tool.inputPayloadRef?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasSidecar = !outputRef.isEmpty || !inputRef.isEmpty

        return SkillListCardSnapshot(
            totalCount: total,
            previewNames: Array(uniqueNames.prefix(3)),
            previewUris: Array(uniqueUris.prefix(3)),
            hasSidecarPayload: hasSidecar
        )
    }

    static func loadSkillListDetail(for tool: CLIMessage.ToolUse) -> SkillListCardDetail? {
        guard isSkillListToolName(tool.name) else { return nil }

        var accumulator = SkillListAccumulator()
        let ordered = [tool.output, tool.input, tool.description]
        for item in ordered {
            mergeSkillListPayload(from: item, into: &accumulator)
        }

        var loadedFromSidecar = false
        var usedSidecarRef: String?
        if accumulator.entries.isEmpty {
            let refs = [tool.outputPayloadRef, tool.inputPayloadRef]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            for ref in refs {
                guard let sidecar = readToolPayloadSidecar(ref: ref),
                      !sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }
                mergeSkillListPayload(from: sidecar, into: &accumulator)
                if !accumulator.entries.isEmpty {
                    loadedFromSidecar = true
                    usedSidecarRef = ref
                    break
                }
            }
        }

        let uniqueEntries = dedupSkillListEntries(accumulator.entries)
        guard !uniqueEntries.isEmpty else { return nil }

        let total = max(accumulator.explicitCount ?? 0, uniqueEntries.count)
        return SkillListCardDetail(
            entries: uniqueEntries,
            totalCount: total,
            sidecarRef: usedSidecarRef,
            loadedFromSidecar: loadedFromSidecar
        )
    }

    static func skillCreatePreviewSnapshot(for tool: CLIMessage.ToolUse) -> SkillCreateCardSnapshot? {
        guard isSkillCreateToolName(tool.name) else { return nil }

        var payload = parseSkillPayload(
            output: tool.output,
            input: tool.input,
            description: tool.description
        )
        enrichSkillPayloadFromSidecarIfNeeded(&payload, tool: tool)

        let overwritten = extractSkillOverwriteFlag(for: tool) ?? false

        let description = payload.promptTemplate.map { firstMeaningfulLine(from: $0, maxLength: 180) }
            ?? payload.description

        return SkillCreateCardSnapshot(
            skillUri: payload.skillUri,
            skillName: payload.skillName,
            descriptionPreview: description,
            overwritten: overwritten
        )
    }

    static func skillDeletePreviewSnapshot(for tool: CLIMessage.ToolUse) -> SkillDeleteCardSnapshot? {
        guard isSkillDeleteToolName(tool.name) else { return nil }

        var payload = parseSkillPayload(
            output: tool.output,
            input: tool.input,
            description: tool.description
        )
        enrichSkillPayloadFromSidecarIfNeeded(&payload, tool: tool)

        return SkillDeleteCardSnapshot(
            skillUri: payload.skillUri,
            skillName: payload.skillName
        )
    }

    private static func parseSkillPayload(
        output: String?,
        input: String?,
        description: String?
    ) -> SkillPayloadAccumulator {
        var payload = SkillPayloadAccumulator()
        let ordered = [output, input, description]

        for item in ordered {
            mergeSkillPayload(from: item, into: &payload)
        }

        if (payload.skillName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true),
           let uri = payload.skillUri,
           let inferred = inferSkillName(from: uri) {
            payload.skillName = inferred
        }

        return payload
    }

    private static func enrichSkillPayloadFromSidecarIfNeeded(
        _ payload: inout SkillPayloadAccumulator,
        tool: CLIMessage.ToolUse
    ) {
        let hasCoreFields = {
            let name = payload.skillName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let uri = payload.skillUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let description = payload.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let prompt = payload.promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !name.isEmpty || !uri.isEmpty || !description.isEmpty || !prompt.isEmpty
        }()

        if hasCoreFields { return }

        let refs = [tool.outputPayloadRef, tool.inputPayloadRef]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for ref in refs {
            guard let sidecar = readToolPayloadSidecar(ref: ref),
                  !sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            let sidecarPayload = parseSkillPayload(output: sidecar, input: nil, description: nil)
            mergeSkillPayload(into: &payload, with: sidecarPayload)
            if (payload.skillName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                || (payload.skillUri?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                || (payload.description?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                || (payload.promptTemplate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false) {
                return
            }
        }
    }

    private static func mergeSkillPayload(
        from raw: String?,
        into payload: inout SkillPayloadAccumulator
    ) {
        guard let raw else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let parsed = parseJSON(trimmed) {
            mergeSkillPayloadFromJSON(parsed, into: &payload)
        } else {
            if payload.skillUri == nil,
               let uri = extractSkillURIFromLooseText(trimmed) {
                payload.skillUri = uri
            }

            if payload.description == nil && !trimmed.hasPrefix("{") && !trimmed.hasPrefix("[") {
                payload.description = firstMeaningfulLine(from: trimmed, maxLength: 220)
            }
        }
    }

    private static func mergeSkillPayload(
        into payload: inout SkillPayloadAccumulator,
        with other: SkillPayloadAccumulator
    ) {
        if payload.skillUri == nil { payload.skillUri = other.skillUri }
        if payload.skillName == nil { payload.skillName = other.skillName }
        if payload.description == nil { payload.description = other.description }
        if payload.promptTemplate == nil { payload.promptTemplate = other.promptTemplate }
    }

    private static func mergeSkillPayloadFromJSON(
        _ root: Any,
        into payload: inout SkillPayloadAccumulator
    ) {
        var queue: [Any] = [root]
        var cursor = 0
        var scanned = 0

        while cursor < queue.count && scanned < 4096 {
            let current = queue[cursor]
            cursor += 1
            scanned += 1

            if let dict = current as? [String: Any] {
                for (key, value) in dict {
                    let normalized = key.lowercased()
                    let stringValue = scalarTextValue(value)

                    if payload.skillUri == nil,
                       isSkillURIKey(normalized),
                       let text = stringValue,
                       let uri = normalizeSkillURI(text) {
                        payload.skillUri = uri
                    }

                    if payload.skillName == nil,
                       isSkillNameKey(normalized),
                       let text = stringValue,
                       !text.isEmpty,
                       normalizeSkillURI(text) == nil {
                        payload.skillName = text
                    }

                    if payload.description == nil,
                       isSkillDescriptionKey(normalized),
                       let text = stringValue,
                       !text.isEmpty {
                        payload.description = firstMeaningfulLine(from: text, maxLength: 220)
                    }

                    if payload.promptTemplate == nil,
                       isSkillPromptKey(normalized),
                       let text = stringValue,
                       !text.isEmpty {
                        payload.promptTemplate = text
                    }

                    if let text = stringValue,
                       (text.hasPrefix("{") || text.hasPrefix("[")),
                       let nested = parseJSON(text) {
                        queue.append(nested)
                    }
                }

                for value in dict.values {
                    queue.append(value)
                }
                continue
            }

            if let array = current as? [Any] {
                queue.append(contentsOf: array)
            }
        }
    }

    private static func mergeSkillListPayload(
        from raw: String?,
        into accumulator: inout SkillListAccumulator
    ) {
        guard let raw else { return }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let parsed = parseJSON(trimmed) {
            mergeSkillListPayloadFromJSON(parsed, into: &accumulator)
            return
        }

        if accumulator.explicitCount == nil {
            accumulator.explicitCount = extractLooseSkillCount(from: trimmed)
        }
    }

    private static func mergeSkillListPayloadFromJSON(
        _ root: Any,
        into accumulator: inout SkillListAccumulator
    ) {
        var queue: [Any] = [root]
        var cursor = 0
        var scanned = 0

        while cursor < queue.count && scanned < 4096 {
            let current = queue[cursor]
            cursor += 1
            scanned += 1

            if let dict = current as? [String: Any] {
                for (key, value) in dict {
                    let normalized = key.lowercased()

                    if isSkillCountKey(normalized),
                       accumulator.explicitCount == nil,
                       let count = scalarIntValue(value),
                       count >= 0 {
                        accumulator.explicitCount = count
                    }

                    if isSkillCollectionKey(normalized),
                       let array = value as? [Any] {
                        for item in array {
                            mergeSkillListSkillItem(item, into: &accumulator)
                        }
                    }

                    if let text = scalarTextValue(value),
                       (text.hasPrefix("{") || text.hasPrefix("[")),
                       let nested = parseJSON(text) {
                        queue.append(nested)
                    }
                }

                for value in dict.values {
                    queue.append(value)
                }
                continue
            }

            if let array = current as? [Any] {
                for item in array {
                    mergeSkillListSkillItem(item, into: &accumulator)
                }
                queue.append(contentsOf: array)
            }
        }
    }

    private static func enrichSkillListFromSidecarIfNeeded(
        _ accumulator: inout SkillListAccumulator,
        tool: CLIMessage.ToolUse
    ) {
        let hasSkillContent = !(accumulator.entries.isEmpty && accumulator.names.isEmpty && accumulator.uris.isEmpty)
        if hasSkillContent { return }

        let refs = [tool.outputPayloadRef, tool.inputPayloadRef]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for ref in refs {
            guard let sidecar = readToolPayloadSidecar(ref: ref),
                  !sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            mergeSkillListPayload(from: sidecar, into: &accumulator)
            if !(accumulator.entries.isEmpty && accumulator.names.isEmpty && accumulator.uris.isEmpty) {
                return
            }
        }
    }

    private static func mergeSkillListSkillItem(
        _ value: Any,
        into accumulator: inout SkillListAccumulator
    ) {
        if let dict = value as? [String: Any] {
            var uri: String?
            var name: String?
            var description: String?

            for (key, entry) in dict {
                let normalized = key.lowercased()
                let text = scalarTextValue(entry)
                if uri == nil,
                   isSkillURIKey(normalized),
                   let text,
                   let normalizedURI = normalizeSkillURI(text) {
                    uri = normalizedURI
                }
                if name == nil,
                   isSkillNameKey(normalized),
                   let text,
                   !text.isEmpty,
                   normalizeSkillURI(text) == nil {
                    name = text
                }
                if description == nil,
                   isSkillDescriptionKey(normalized),
                   let text,
                   !text.isEmpty {
                    description = firstMeaningfulLine(from: text, maxLength: 220)
                }
            }

            if let uri {
                accumulator.uris.append(uri)
            }
            let resolvedName: String? = {
                if let name { return name }
                if let uri, let inferred = inferSkillName(from: uri) { return inferred }
                return nil
            }()

            if let resolvedName {
                accumulator.names.append(resolvedName)
                let entryId = uri ?? "name:\(resolvedName)"
                accumulator.entries.append(
                    SkillListCardEntry(
                        id: entryId,
                        skillUri: uri,
                        skillName: resolvedName,
                        description: description
                    )
                )
            }
            return
        }

        if let text = scalarTextValue(value),
           let uri = normalizeSkillURI(text) {
            accumulator.uris.append(uri)
            if let inferred = inferSkillName(from: uri) {
                accumulator.names.append(inferred)
                accumulator.entries.append(
                    SkillListCardEntry(
                        id: uri,
                        skillUri: uri,
                        skillName: inferred,
                        description: nil
                    )
                )
            }
        }
    }

    private static func scalarTextValue(_ value: Any?) -> String? {
        guard let value else { return nil }

        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        if let number = value as? NSNumber {
            let text = number.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }

        return nil
    }

    private static func scalarIntValue(_ value: Any?) -> Int? {
        guard let value else { return nil }

        if let number = value as? NSNumber {
            return number.intValue
        }

        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(trimmed)
        }

        return nil
    }

    private static func scalarBoolValue(_ value: Any?) -> Bool? {
        guard let value else { return nil }

        if let bool = value as? Bool {
            return bool
        }

        if let number = value as? NSNumber {
            return number.boolValue
        }

        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "true" || normalized == "1" || normalized == "yes" {
                return true
            }
            if normalized == "false" || normalized == "0" || normalized == "no" {
                return false
            }
        }

        return nil
    }

    private static func isSkillCollectionKey(_ key: String) -> Bool {
        key == "skills" || key == "items" || key == "data" || key == "result"
    }

    private static func isSkillCountKey(_ key: String) -> Bool {
        key == "count"
            || key == "total"
            || key == "totalcount"
            || key == "skillcount"
            || key == "availablecount"
            || key == "skillavailablecount"
    }

    private static func extractLooseSkillCount(from text: String) -> Int? {
        let pattern = #"(?:count|total)\D{0,8}(\d{1,5})"#
        guard let regex = cachedRegex(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }

        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: fullRange),
              match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return Int(String(text[capture]))
    }

    private static func dedupSkillListEntries(_ entries: [SkillListCardEntry]) -> [SkillListCardEntry] {
        var seen: Set<String> = []
        var result: [SkillListCardEntry] = []
        for entry in entries {
            let uri = entry.skillUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = uri.isEmpty
                ? "name:\(entry.skillName.lowercased())"
                : "uri:\(uri)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            result.append(entry)
        }
        return result
    }

    private static func extractSkillOverwriteFlag(
        output: String?,
        input: String?,
        description: String?
    ) -> Bool? {
        let ordered = [output, input, description]
        for raw in ordered {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let parsed = parseJSON(trimmed) else { continue }
            if let resolved = scanOverwriteFlag(from: parsed) {
                return resolved
            }
        }
        return nil
    }

    private static func extractSkillOverwriteFlag(for tool: CLIMessage.ToolUse) -> Bool? {
        if let resolved = extractSkillOverwriteFlag(
            output: tool.output,
            input: tool.input,
            description: tool.description
        ) {
            return resolved
        }

        let refs = [tool.outputPayloadRef, tool.inputPayloadRef]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for ref in refs {
            guard let sidecar = readToolPayloadSidecar(ref: ref),
                  !sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }
            if let resolved = extractSkillOverwriteFlag(output: sidecar, input: nil, description: nil) {
                return resolved
            }
        }
        return nil
    }

    private static func scanOverwriteFlag(from root: Any) -> Bool? {
        var queue: [Any] = [root]
        var cursor = 0
        var scanned = 0

        while cursor < queue.count && scanned < 2048 {
            let current = queue[cursor]
            cursor += 1
            scanned += 1

            if let dict = current as? [String: Any] {
                for (key, value) in dict {
                    let normalized = key.lowercased()
                    if normalized == "overwritten"
                        || normalized == "overwrite"
                        || normalized == "isoverwritten"
                        || normalized == "overwriteexisting" {
                        if let boolValue = scalarBoolValue(value) {
                            return boolValue
                        }
                    }

                    if let text = scalarTextValue(value),
                       (text.hasPrefix("{") || text.hasPrefix("[")),
                       let nested = parseJSON(text) {
                        queue.append(nested)
                    }
                }
                queue.append(contentsOf: dict.values)
                continue
            }

            if let array = current as? [Any] {
                queue.append(contentsOf: array)
            }
        }

        return nil
    }

    private static func isSkillURIKey(_ key: String) -> Bool {
        key == "skilluri"
            || key == "skill_uri"
            || key == "uri"
            || key == "skillurl"
            || key == "skillid"
            || key == "skill_id"
            || key == "id"
    }

    private static func isSkillNameKey(_ key: String) -> Bool {
        key == "name"
            || key == "skillname"
            || key == "skill_name"
            || key == "title"
            || key == "skillid"
            || key == "skill_id"
            || key == "id"
            || key == "identifier"
    }

    private static func isSkillDescriptionKey(_ key: String) -> Bool {
        key == "description" || key == "desc" || key == "summary"
    }

    private static func isSkillPromptKey(_ key: String) -> Bool {
        key == "prompttemplate"
            || key == "prompt_template"
            || key == "prompt"
            || key == "template"
            || key == "instructions"
    }

    private static func normalizeSkillURI(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("ctxgo://") {
            return trimmed
        }
        if trimmed.contains("://"), trimmed.lowercased().contains("skill") {
            return trimmed
        }
        return nil
    }

    private static func extractSkillURIFromLooseText(_ text: String) -> String? {
        let pattern = #"ctxgo://[A-Za-z0-9._~:/?#\[\]@!$&'()*+,;=%-]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              let matchRange = Range(match.range, in: text) else {
            return nil
        }
        let raw = String(text[matchRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? nil : raw
    }

    private static func inferSkillName(from uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tail = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        let normalized = tail.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func readToolPayloadSidecar(ref: String) -> String? {
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

        for url in candidates where fileManager.fileExists(atPath: url.path) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }

        return nil
    }
}
