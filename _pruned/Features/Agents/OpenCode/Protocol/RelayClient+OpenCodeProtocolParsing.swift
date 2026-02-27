import Foundation

extension RelayClient {
    func isOpenCodeACPProvider(
        providerHint: String?,
        contentType: String
    ) -> Bool {
        if contentType == "opencode" {
            return true
        }

        if let provider = providerHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           provider == "opencode" {
            return true
        }
        return false
    }

    func parseOpenCodeACPContent(
        normalized: [String: Any],
        canonicalType: String,
        messageId: String?,
        fallbackRunId: String?
    ) -> (blocks: [[String: Any]], runId: String?)? {
        let resolved = resolveOpenCodeACPEnvelope(normalized: normalized, canonicalType: canonicalType)
        let payload = (resolved.payload as? [String: Any]) ?? normalized
        guard let parsed = parseOpenCodeEventEnvelope(
            type: resolved.type,
            data: payload,
            messageId: messageId
        ) else {
            return nil
        }
        return (parsed.blocks, parsed.runId ?? fallbackRunId)
    }

    func parseOpenCodeEventEnvelope(
        type: String,
        data: [String: Any],
        messageId: String?
    ) -> (blocks: [[String: Any]], runId: String?)? {
        let runId = preferredACPEventRunIdentifier(from: data, fallback: messageId)
        if openCodeShouldSilenceEvent(type: type, data: data) {
            return ([], runId)
        }

        switch type {
        case "available.commands.update", "available.commands", "available_commands_update":
            return ([], runId)

        case "task.started", "task_started", "task-started":
            // OpenCode lifecycle bootstrap signal: keep silent in timeline cards.
            return ([], runId)

        case "agent.message", "agent.message.chunk":
            if let text = openCodeExtractChunkText(
                data["content"] ?? data["message"] ?? data["text"] ?? data
            ) {
                return ([["type": "text", "text": text]], runId)
            }
            return nil

        case "agent.thought", "agent.thought.chunk", "thinking", "reasoning":
            if let text = openCodeExtractChunkText(
                data["content"] ?? data["message"] ?? data["text"] ?? data
            ) {
                return ([["type": "thinking", "text": text]], runId)
            }
            return nil

        case "message.part.updated":
            guard let part = data["part"] as? [String: Any] else { return nil }
            let blocks = parseOpenCodeMessagePart(part)
            guard !blocks.isEmpty else { return nil }
            let partRunId = (part["id"] as? String) ?? runId ?? messageId
            return (blocks, partRunId)

        case "todo.updated":
            let todos = data["todos"]
                ?? (data["properties"] as? [String: Any])?["todos"]
            guard let payload = stringifyValue(todos), !payload.isEmpty else { return nil }
            let idBase = firstNonEmptyString([
                data["id"] as? String,
                data["todoId"] as? String,
                data["threadID"] as? String,
                data["threadId"] as? String,
                runId,
                messageId
            ]) ?? UUID().uuidString
            let id = "todo:\(idBase)"
            return ([[
                "type": "tool_result",
                "toolUseId": id,
                "toolName": "TodoWrite",
                "text": payload,
                "isError": false
            ]], runId ?? id)

        case "plan":
            let entries = data["entries"]
                ?? (data["payload"] as? [String: Any])?["entries"]
            guard let payload = stringifyValue(entries), !payload.isEmpty else { return nil }
            let idBase = firstNonEmptyString([
                data["id"] as? String,
                data["turnId"] as? String,
                data["turn_id"] as? String,
                runId,
                messageId
            ]) ?? UUID().uuidString
            let id = "todo:\(idBase)"
            return ([[
                "type": "tool_result",
                "toolUseId": id,
                "toolName": "TodoWrite",
                "text": payload,
                "isError": false
            ]], runId ?? id)

        case "tool.call", "tool.call.update":
            let toolId = firstNonEmptyString([
                data["toolCallId"] as? String,
                data["tool_call_id"] as? String,
                data["toolUseId"] as? String,
                data["tool_use_id"] as? String,
                data["callId"] as? String,
                data["call_id"] as? String,
                data["id"] as? String,
                messageId
            ]) ?? UUID().uuidString

            let rawStatus = (data["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? "pending"
            let lifecycleRunId = openCodeBackgroundTaskIdentifier(from: data)
            let toolName = openCodeResolveToolName(from: data)
            let inputPayload = openCodeToolInputPayload(from: data)
            var useBlock: [String: Any] = [
                "type": "tool_use",
                "toolUseId": toolId,
                "toolName": toolName,
                "toolInput": stringifyValue(inputPayload) ?? "{}"
            ]
            if let description = firstNonEmptyString([
                data["title"] as? String,
                data["kind"] as? String
            ]) {
                useBlock["description"] = description
            }
            if let kind = data["kind"] as? String,
               !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                useBlock["toolKind"] = kind
            }

            let terminalStatuses: Set<String> = ["completed", "success", "failed", "error", "cancelled", "canceled"]
            guard terminalStatuses.contains(rawStatus) else {
                // OpenCode tool progress updates are high-frequency; keep timeline cards terminal-only.
                return ([], lifecycleRunId ?? runId ?? toolId)
            }

            let rawOutputPayload = data["rawOutput"]
                ?? data["output"]
                ?? data["content"]
                ?? data["error"]
                ?? (data["payload"] as? [String: Any])?["output"]
                ?? (data["payload"] as? [String: Any])?["content"]
            let outputText = stringifyValue(rawOutputPayload) ?? ""
            let isError = ["failed", "error"].contains(rawStatus)
            if outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ([useBlock], lifecycleRunId ?? runId ?? toolId)
            }
            let resultBlock: [String: Any] = [
                "type": "tool_result",
                "toolUseId": toolId,
                "toolName": toolName,
                "text": outputText,
                "isError": isError
            ]
            return ([useBlock, resultBlock], lifecycleRunId ?? runId ?? toolId)

        case "permission.asked":
            let permissionId = firstNonEmptyString([
                data["id"] as? String,
                data["permissionId"] as? String,
                messageId
            ]) ?? UUID().uuidString
            let toolPayload = data["tool"] as? [String: Any]
            let toolName = normalizeToolName(
                (toolPayload?["toolName"] as? String)
                    ?? (toolPayload?["name"] as? String)
                    ?? (toolPayload?["kind"] as? String)
                    ?? "permission"
            )
            let input: [String: Any] = [
                "tool": toolPayload as Any,
                "permission": data["permission"] as Any,
                "patterns": data["patterns"] as Any,
                "metadata": data["metadata"] as Any
            ]
            let permission = openCodePermissionPayload(
                data["permission"],
                fallbackId: permissionId,
                defaultStatus: "pending"
            )
            var block: [String: Any] = [
                "type": "tool_use",
                "toolUseId": permissionId,
                "toolName": toolName,
                "toolInput": stringifyValue(input) ?? "{}"
            ]
            if let permission {
                block["permission"] = permission
            }
            return ([block], runId ?? permissionId)

        case "permission.replied":
            let permissionId = firstNonEmptyString([
                data["requestID"] as? String,
                data["requestId"] as? String,
                data["permissionId"] as? String,
                data["id"] as? String,
                messageId
            ]) ?? UUID().uuidString
            let reply = ((data["reply"] as? String)
                ?? (data["result"] as? String)
                ?? (data["decision"] as? String)
                ?? "unknown")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedReply = reply.lowercased()
            let resolvedStatus: String = {
                if ["approved", "allow", "allowed", "proceed_once", "proceed_always"].contains(normalizedReply) {
                    return "approved"
                }
                if ["reject", "rejected", "deny", "denied"].contains(normalizedReply) {
                    return "denied"
                }
                if ["cancel", "cancelled", "canceled", "abort", "aborted"].contains(normalizedReply) {
                    return "canceled"
                }
                return "pending"
            }()
            let permission = openCodePermissionPayload(
                data["permission"],
                fallbackId: permissionId,
                defaultStatus: resolvedStatus,
                decision: reply
            )
            let isError = resolvedStatus == "denied" || resolvedStatus == "canceled"
            var block: [String: Any] = [
                "type": "tool_result",
                "toolUseId": permissionId,
                "toolName": "permission",
                "text": "Permission reply: \(reply)",
                "isError": isError
            ]
            if let permission {
                block["permission"] = permission
            }
            return ([block], runId ?? permissionId)

        default:
            return nil
        }
    }

    private func resolveOpenCodeACPEnvelope(
        normalized: [String: Any],
        canonicalType: String
    ) -> (type: String, payload: Any) {
        var resolvedType = canonicalType.isEmpty ? "event" : canonicalType
        var resolvedPayload: Any = normalized

        if resolvedType == "event" {
            let wrappedName = canonicalACPEventType((normalized["name"] as? String) ?? "")
            if !wrappedName.isEmpty {
                resolvedType = wrappedName
            }
            if let payload = normalized["payload"] {
                resolvedPayload = payload
            }
        }

        return (resolvedType, resolvedPayload)
    }

    private func parseOpenCodeMessagePart(_ part: [String: Any]) -> [[String: Any]] {
        guard let partType = (part["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return []
        }

        switch partType {
        case "text", "output_text", "input_text":
            guard let text = (part["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty else {
                return []
            }
            let blockType = openCodeLooksLikePlanningScratch(text) ? "thinking" : "text"
            return [["type": blockType, "text": text]]

        case "thinking", "reasoning":
            guard let text = ((part["thinking"] as? String) ?? (part["text"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty else {
                return []
            }
            return [["type": "thinking", "text": text]]

        case "tool":
            let toolId = firstNonEmptyString([
                part["callID"] as? String,
                part["callId"] as? String,
                part["toolUseId"] as? String,
                part["toolCallId"] as? String,
                part["id"] as? String
            ]) ?? UUID().uuidString
            let toolName = openCodeResolveToolName(from: part)
            let toolInput = stringifyValue(
                (part["state"] as? [String: Any])?["input"]
                    ?? part["input"]
                    ?? part["arguments"]
            ) ?? "{}"
            var useBlock: [String: Any] = [
                "type": "tool_use",
                "toolUseId": toolId,
                "toolName": toolName,
                "toolInput": toolInput
            ]
            if let title = ((part["state"] as? [String: Any])?["title"] as? String),
               !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                useBlock["description"] = title
            }

            let stateStatus = ((part["state"] as? [String: Any])?["status"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            guard stateStatus == "completed" || stateStatus == "error" else {
                return [useBlock]
            }

            let outputPayload = (part["state"] as? [String: Any])?["output"]
                ?? (part["state"] as? [String: Any])?["error"]
                ?? part["output"]
                ?? part["error"]
            let outputText = stringifyValue(outputPayload) ?? ""
            if outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [useBlock]
            }
            let resultBlock: [String: Any] = [
                "type": "tool_result",
                "toolUseId": toolId,
                "toolName": toolName,
                "text": outputText,
                "isError": stateStatus == "error"
            ]
            return [useBlock, resultBlock]

        default:
            return []
        }
    }

    private func openCodeResolveToolName(from data: [String: Any]) -> String {
        if openCodeHasStructuredBackgroundLifecycleHint(from: data) {
            return "BackgroundTask"
        }

        let primaryCandidates: [String?] = [
            data["toolName"] as? String,
            data["name"] as? String,
            data["title"] as? String,
            data["kind"] as? String,
            data["toolKind"] as? String,
            data["tool"] as? String
        ]
        for candidate in primaryCandidates {
            guard let candidate else { continue }
            if let mapped = openCodeSemanticToolName(from: candidate) {
                return mapped
            }
        }

        if let inferred = openCodeInferredToolNameFromPayload(data) {
            return inferred
        }

        let secondaryCandidates: [String?] = [
            data["kind"] as? String,
            data["toolKind"] as? String,
            data["tool"] as? String
        ]
        for candidate in secondaryCandidates {
            guard let candidate else { continue }
            let normalized = canonicalACPEventType(candidate)
            if normalized == "other" || normalized.isEmpty {
                continue
            }
            if let mapped = openCodeSemanticToolName(from: candidate) {
                return mapped
            }
            return normalizeToolName(candidate)
        }

        if let fallback = openCodePreferredFallbackToolName(from: primaryCandidates + secondaryCandidates) {
            return normalizeToolName(fallback)
        }
        return "Tool"
    }

    private func openCodeInferredToolNameFromPayload(_ data: [String: Any]) -> String? {
        if openCodeLooksLikeTitleChange(from: data) {
            return "ChangeTitle"
        }

        let candidates = openCodeCandidatePayloadObjects(from: data)

        for candidate in candidates {
            let hasPattern = openCodeFirstNonEmptyString(in: candidate, keys: ["pattern", "glob", "query"]) != nil
            let hasPath = openCodeFirstNonEmptyString(in: candidate, keys: ["path", "filePath", "file_path", "uri", "target"]) != nil
            if hasPattern && hasPath {
                return "Glob"
            }
        }

        for candidate in candidates {
            let hasPath = openCodeFirstNonEmptyString(in: candidate, keys: ["filePath", "file_path", "path", "uri", "target"]) != nil
            if hasPath {
                return "Read"
            }
        }

        return nil
    }

    private func openCodeCandidatePayloadObjects(from data: [String: Any]) -> [[String: Any]] {
        var candidates: [[String: Any]] = [data]
        if let rawInput = data["rawInput"] as? [String: Any] {
            candidates.append(rawInput)
        }
        if let input = data["input"] as? [String: Any] {
            candidates.append(input)
        }
        if let payload = data["payload"] as? [String: Any] {
            candidates.append(payload)
            if let payloadInput = payload["input"] as? [String: Any] {
                candidates.append(payloadInput)
            }
        }
        if let state = data["state"] as? [String: Any],
           let stateInput = state["input"] as? [String: Any] {
            candidates.append(stateInput)
        }
        return candidates
    }

    private func openCodeLooksLikeTitleChange(from data: [String: Any]) -> Bool {
        if openCodeExtractChangedTitleFromData(data) != nil {
            return true
        }

        let titleKeys = ["title", "new_title", "newTitle", "session_title", "chat_title", "updated_title", "renamed_to"]
        for candidate in openCodeCandidatePayloadObjects(from: data) {
            guard let title = openCodeFirstNonEmptyString(in: candidate, keys: titleKeys) else {
                continue
            }
            if openCodeLooksLikeNonTitleLabel(title) {
                continue
            }
            if openCodeLooksLikeTitleChangeInputPayload(candidate) {
                return true
            }
        }

        return false
    }

    private func openCodeLooksLikeTitleChangeInputPayload(_ payload: [String: Any]) -> Bool {
        let keys = Set(payload.keys.map { canonicalACPEventType($0) })
        let disqualifying: Set<String> = [
            "path", "filepath", "file_path", "uri", "target",
            "pattern", "glob", "query",
            "command", "cmd", "script",
            "kind", "status", "state",
            "task_id", "taskid", "sessionid", "session_id",
            "subagent_type", "run_in_background",
            "toolcallid", "tool_call_id", "callid", "call_id",
            "locations"
        ]

        if !keys.isDisjoint(with: disqualifying) {
            return false
        }

        let titleKeys: Set<String> = [
            "title", "new_title", "newtitle", "session_title",
            "chat_title", "updated_title", "renamed_to"
        ]
        return !keys.isDisjoint(with: titleKeys)
    }

    private func openCodeLooksLikeNonTitleLabel(_ raw: String) -> Bool {
        let normalized = canonicalACPEventType(raw)
        if normalized.isEmpty {
            return true
        }

        let lowSignal: Set<String> = [
            "tool", "other", "read", "glob", "search",
            "task", "bash", "run", "permission",
            "background", "background_task", "background_output", "background_cancel"
        ]
        return lowSignal.contains(normalized)
    }

    private func openCodeExtractChangedTitleFromData(_ data: [String: Any]) -> String? {
        let payload = data["payload"] as? [String: Any]
        let state = data["state"] as? [String: Any]
        let stateOutput = state?["output"] as? [String: Any]
        let stateInput = state?["input"] as? [String: Any]

        let candidates: [Any?] = [
            data["rawOutput"],
            data["output"],
            data["content"],
            data["message"],
            data["text"],
            payload?["output"],
            payload?["content"],
            payload?["message"],
            stateOutput,
            state?["output"],
            state?["error"],
            stateInput
        ]

        for value in candidates {
            for text in openCodeExtractTitleChangeTextCandidates(from: value) {
                if let title = openCodeExtractChangedTitleFromText(text) {
                    return title
                }
            }
        }
        return nil
    }

    private func openCodeExtractTitleChangeTextCandidates(from value: Any?) -> [String] {
        guard let value else { return [] }

        var results: [String] = []

        func appendCandidate(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if !results.contains(trimmed) {
                results.append(trimmed)
            }
        }

        func visit(_ current: Any, depth: Int) {
            if depth > 8 { return }

            if let text = current as? String {
                appendCandidate(text)
                return
            }

            if let dict = current as? [String: Any] {
                for key in ["output", "result", "text", "content", "message", "error"] {
                    if let nested = dict[key] {
                        visit(nested, depth: depth + 1)
                    }
                }
                for key in ["rawOutput", "rawInput", "payload", "state", "data", "metadata", "input"] {
                    if let nested = dict[key] {
                        visit(nested, depth: depth + 1)
                    }
                }
                return
            }

            if let list = current as? [Any] {
                for item in list {
                    visit(item, depth: depth + 1)
                }
            }
        }

        visit(value, depth: 0)

        if let serialized = stringifyValue(value) {
            appendCandidate(serialized)
        }

        return results
    }

    private func openCodeExtractChangedTitleFromText(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let patterns = [
            #"Successfully changed chat title to:\s*\"([^\"]+)\""#,
            #"(?i)(?:set|rename(?:d)?|change(?:d)?|update(?:d)?)\s+(?:the\s+)?(?:chat\s+|session\s+)?title(?:\s+to)?\s*[\"“']([^\"”'\n]+)"#,
            #"(?i)标题(?:已)?(?:更新|修改|变更)(?:为|成)?\s*[:：]?\s*[\"“]?([^\"”\n]+)"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            guard let match = regex.firstMatch(in: trimmed, options: [], range: range),
                  match.numberOfRanges > 1,
                  let group = Range(match.range(at: 1), in: trimmed) else {
                continue
            }
            let title = String(trimmed[group]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return title
            }
        }

        return nil
    }

    private func openCodeFirstNonEmptyString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        for nestedKey in ["rawInput", "input", "payload", "data", "params", "arguments", "state"] {
            if let nested = dict[nestedKey] as? [String: Any],
               let found = openCodeFirstNonEmptyString(in: nested, keys: keys) {
                return found
            }
        }

        return nil
    }

    private func openCodeSemanticToolName(from raw: String) -> String? {
        let normalized = canonicalACPEventType(raw)
        guard !normalized.isEmpty else { return nil }

        if normalized.contains("todo") || normalized == "plan" {
            return "TodoWrite"
        }
        if normalized.contains("cgo_change_title")
            || normalized.contains("change_title")
            || normalized.contains("changetitle") {
            return "ChangeTitle"
        }
        if normalized.contains("background") {
            return "BackgroundTask"
        }
        if normalized == "task" || normalized.contains("subagent") {
            return "Task"
        }
        if normalized.contains("read") {
            return "Read"
        }
        if normalized.contains("glob") || normalized.contains("search") || normalized.contains("grep") {
            return "Glob"
        }
        if normalized.contains("bash")
            || normalized.contains("command")
            || normalized == "run" {
            return "Bash"
        }
        return nil
    }

    private func openCodePreferredFallbackToolName(from candidates: [String?]) -> String? {
        for candidate in candidates {
            guard let raw = candidate?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !raw.isEmpty else {
                continue
            }
            let normalized = canonicalACPEventType(raw)
            if normalized == "other" {
                continue
            }
            return raw
        }
        return nil
    }

    private func openCodeHasStructuredBackgroundLifecycleHint(from data: [String: Any]) -> Bool {
        if openCodeExtractBackgroundTaskID(from: data) != nil {
            return true
        }

        if openCodeHasRunInBackgroundFlag(from: data) {
            return true
        }

        if let title = data["title"] as? String,
           openCodeIsBackgroundLifecycleTitle(title) {
            return true
        }

        if let name = data["name"] as? String,
           openCodeIsBackgroundLifecycleTitle(name) {
            return true
        }

        return false
    }

    private func openCodeBackgroundTaskIdentifier(from data: [String: Any]) -> String? {
        if let taskID = openCodeExtractBackgroundTaskID(from: data) {
            return taskID
        }

        if openCodeHasStructuredBackgroundLifecycleHint(from: data),
           let sessionID = openCodeExtractBackgroundSessionID(from: data) {
            return sessionID
        }
        return nil
    }

    private func openCodeExtractBackgroundTaskID(from data: [String: Any]) -> String? {
        let rawInput = data["rawInput"] as? [String: Any]
        let rawOutput = data["rawOutput"] as? [String: Any]
        let outputMetadata = rawOutput?["metadata"] as? [String: Any]
        let payload = data["payload"] as? [String: Any]

        let candidates: [String?] = [
            openCodeTrimmedString(data["task_id"]),
            openCodeTrimmedString(data["taskId"]),
            openCodeTrimmedString(rawInput?["task_id"]),
            openCodeTrimmedString(rawInput?["taskId"]),
            openCodeTrimmedString(rawOutput?["task_id"]),
            openCodeTrimmedString(rawOutput?["taskId"]),
            openCodeTrimmedString(outputMetadata?["task_id"]),
            openCodeTrimmedString(outputMetadata?["taskId"]),
            openCodeTrimmedString(payload?["task_id"]),
            openCodeTrimmedString(payload?["taskId"])
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            if openCodeLooksLikeBackgroundTaskIdentifier(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func openCodeExtractBackgroundSessionID(from data: [String: Any]) -> String? {
        let rawInput = data["rawInput"] as? [String: Any]
        let rawOutput = data["rawOutput"] as? [String: Any]
        let outputMetadata = rawOutput?["metadata"] as? [String: Any]
        let payload = data["payload"] as? [String: Any]

        let candidates: [String?] = [
            openCodeTrimmedString(data["sessionId"]),
            openCodeTrimmedString(data["session_id"]),
            openCodeTrimmedString(rawInput?["sessionId"]),
            openCodeTrimmedString(rawInput?["session_id"]),
            openCodeTrimmedString(rawOutput?["sessionId"]),
            openCodeTrimmedString(rawOutput?["session_id"]),
            openCodeTrimmedString(outputMetadata?["sessionId"]),
            openCodeTrimmedString(outputMetadata?["session_id"]),
            openCodeTrimmedString(payload?["sessionId"]),
            openCodeTrimmedString(payload?["session_id"])
        ]

        for candidate in candidates {
            guard let candidate else { continue }
            return candidate
        }
        return nil
    }

    private func openCodeHasRunInBackgroundFlag(from data: [String: Any]) -> Bool {
        if openCodeBool(data["run_in_background"]) {
            return true
        }
        let rawInput = data["rawInput"] as? [String: Any]
        if openCodeBool(rawInput?["run_in_background"]) {
            return true
        }
        return false
    }

    private func openCodeIsBackgroundLifecycleTitle(_ raw: String) -> Bool {
        let normalized = canonicalACPEventType(raw)
        if normalized == "background_output"
            || normalized == "background_cancel"
            || normalized == "background_task"
            || normalized == "background" {
            return true
        }
        return false
    }

    private func openCodeTrimmedString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func openCodeBool(_ value: Any?) -> Bool {
        if let boolValue = value as? Bool {
            return boolValue
        }
        if let stringValue = value as? String {
            let normalized = stringValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return normalized == "true" || normalized == "1" || normalized == "yes"
        }
        return false
    }

    private func openCodeTruncated(_ raw: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        if raw.count <= maxLength {
            return raw
        }
        return String(raw.prefix(maxLength))
    }

    private func openCodeLooksLikeBackgroundTaskIdentifier(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.hasPrefix("bg_")
            || normalized.hasPrefix("bg-")
    }

    private func openCodeToolInputPayload(from data: [String: Any]) -> Any {
        if openCodeHasStructuredBackgroundLifecycleHint(from: data) {
            return openCodeCompactBackgroundLifecycleInput(from: data)
        }

        let extractedTaskID = openCodeExtractBackgroundTaskID(from: data)
        let extractedSessionID = openCodeExtractBackgroundSessionID(from: data)
        let runInBackground = openCodeHasRunInBackgroundFlag(from: data)

        let metadata = ((data["rawOutput"] as? [String: Any])?["metadata"] as? [String: Any]) ?? [:]
        let metadataDescription = openCodeTrimmedString(metadata["description"])
        let metadataPrompt = openCodeTrimmedString(metadata["prompt"])

        if var rawInput = data["rawInput"] as? [String: Any] {
            if let extractedTaskID {
                if rawInput["task_id"] == nil { rawInput["task_id"] = extractedTaskID }
                if rawInput["taskId"] == nil { rawInput["taskId"] = extractedTaskID }
            }
            if let extractedSessionID, rawInput["sessionId"] == nil {
                rawInput["sessionId"] = extractedSessionID
            }
            if runInBackground, rawInput["run_in_background"] == nil {
                rawInput["run_in_background"] = true
            }
            if let metadataDescription, rawInput["description"] == nil {
                rawInput["description"] = metadataDescription
            }
            if let metadataPrompt, rawInput["prompt"] == nil {
                rawInput["prompt"] = metadataPrompt
            }
            return rawInput
        }

        var payload: [String: Any] = [:]
        for key in ["kind", "title", "status", "locations", "sessionUpdate", "task_id", "taskId"] {
            if let value = data[key], !(value is NSNull) {
                payload[key] = value
            }
        }
        if let input = data["input"], !(input is NSNull) {
            payload["input"] = input
        }
        if let extractedTaskID {
            if payload["task_id"] == nil { payload["task_id"] = extractedTaskID }
            if payload["taskId"] == nil { payload["taskId"] = extractedTaskID }
        }
        if let extractedSessionID, payload["sessionId"] == nil {
            payload["sessionId"] = extractedSessionID
        }
        if runInBackground, payload["run_in_background"] == nil {
            payload["run_in_background"] = true
        }
        if let metadataDescription, payload["description"] == nil {
            payload["description"] = metadataDescription
        }
        if let metadataPrompt, payload["prompt"] == nil {
            payload["prompt"] = metadataPrompt
        }

        if payload.isEmpty {
            return data
        }
        return payload
    }

    private func openCodeCompactBackgroundLifecycleInput(from data: [String: Any]) -> [String: Any] {
        let rawInput = data["rawInput"] as? [String: Any]
        let metadata = ((data["rawOutput"] as? [String: Any])?["metadata"] as? [String: Any]) ?? [:]

        var payload: [String: Any] = [:]
        if let title = openCodeTrimmedString(data["title"]),
           !openCodeIsBackgroundLifecycleTitle(title) {
            payload["title"] = openCodeTruncated(title, maxLength: 80)
        }
        if let status = openCodeTrimmedString(data["status"]) {
            payload["status"] = status
        }
        if let kind = openCodeTrimmedString(data["kind"]) {
            payload["kind"] = kind
        }
        if let taskID = openCodeExtractBackgroundTaskID(from: data) {
            payload["task_id"] = taskID
            payload["taskId"] = taskID
        }
        if let sessionID = openCodeExtractBackgroundSessionID(from: data) {
            payload["sessionId"] = sessionID
        }
        if openCodeHasRunInBackgroundFlag(from: data) {
            payload["run_in_background"] = true
        }
        if let subagentType = openCodeTrimmedString(rawInput?["subagent_type"]) {
            payload["subagent_type"] = subagentType
        }
        if let description = firstNonEmptyString([
            openCodeTrimmedString(rawInput?["description"]),
            openCodeTrimmedString(metadata["description"])
        ]) {
            payload["description"] = openCodeTruncated(description, maxLength: 140)
        }
        if let prompt = firstNonEmptyString([
            openCodeTrimmedString(rawInput?["prompt"]),
            openCodeTrimmedString(metadata["prompt"])
        ]) {
            payload["prompt"] = openCodeTruncated(prompt, maxLength: 260)
        }

        if payload.isEmpty {
            return ["status": (openCodeTrimmedString(data["status"]) ?? "pending")]
        }
        return payload
    }

    private func openCodePermissionPayload(
        _ raw: Any?,
        fallbackId: String?,
        defaultStatus: String?,
        decision: String? = nil
    ) -> [String: Any]? {
        guard var permission = raw as? [String: Any] else {
            guard let fallbackId else { return nil }
            var payload: [String: Any] = [
                "id": fallbackId,
                "status": defaultStatus ?? "pending"
            ]
            if let decision, !decision.isEmpty {
                payload["decision"] = decision
            }
            return payload
        }

        if permission["id"] == nil, let fallbackId {
            permission["id"] = fallbackId
        }
        if permission["status"] == nil {
            permission["status"] = defaultStatus ?? "pending"
        }
        if permission["decision"] == nil, let decision, !decision.isEmpty {
            permission["decision"] = decision
        }
        return permission
    }

    private func openCodeExtractChunkText(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }

        if let dict = value as? [String: Any] {
            if let text = dict["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let content = dict["content"] as? [String: Any],
               let text = content["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let nested = dict["content"] as? String,
               !nested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return nested
            }
        }

        if let array = value as? [[String: Any]] {
            for item in array {
                if let text = openCodeExtractChunkText(item) {
                    return text
                }
            }
        }

        return nil
    }

    private func openCodeLooksLikePlanningScratch(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard trimmed.count <= 360 else { return false }

        let compact = trimmed.replacingOccurrences(of: "**", with: "")
        let lines = compact
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 3 else { return false }
        guard lines[0].lowercased().contains("plan") else { return false }

        let shortLikeCount = lines.dropFirst().filter { raw in
            let normalized = raw.replacingOccurrences(
                of: #"^[\-\*\u{2022}\d\.\)\s]+"#,
                with: "",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return false }
            let words = normalized.split(whereSeparator: \.isWhitespace)
            return normalized.count <= 28 && words.count <= 3
        }.count

        return shortLikeCount >= max(2, Int(Double(lines.count - 1) * 0.5))
    }

    private func openCodeShouldSilenceEvent(type: String, data: [String: Any]) -> Bool {
        let normalizedType = canonicalACPEventType(type)
        let silentTypes: Set<String> = [
            "usage.update",
            "usage_update",
            "usage",
            "runtime.metadata",
            "event.runtime.metadata",
            "session.metadata",
            "session.info",
            "session.update"
        ]
        if silentTypes.contains(normalizedType) {
            return true
        }

        if let sessionUpdate = (data["sessionUpdate"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           sessionUpdate == "usage_update" {
            return true
        }

        let sourceCandidates: [String?] = [
            data["source"] as? String,
            (data["metadata"] as? [String: Any])?["source"] as? String
        ]
        for source in sourceCandidates {
            guard let source = source?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                !source.isEmpty else {
                continue
            }
            if source == "acp-new-session" || source == "acp.new.session" {
                return true
            }
        }

        return false
    }
}
