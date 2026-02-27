import Foundation

extension RelayClient {
    func isClaudeACPProvider(
        providerHint: String?,
        contentType: String
    ) -> Bool {
        if contentType == "claude" || contentType == "claudecode" {
            return true
        }

        if let provider = providerHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           provider == "claude" || provider == "claudecode" {
            return true
        }
        return false
    }

    func parseClaudeACPContent(
        normalized: [String: Any],
        canonicalType: String,
        messageId: String?,
        fallbackRunId: String?
    ) -> (blocks: [[String: Any]], runId: String?)? {
        let resolved = resolveClaudeACPEnvelope(normalized: normalized, canonicalType: canonicalType)
        let payload = (resolved.payload as? [String: Any]) ?? normalized
        let runId = preferredACPEventRunIdentifier(from: payload, fallback: fallbackRunId ?? messageId)

        switch resolved.type {
        case "agent.message", "agent.message.chunk", "message":
            if let text = claudeExtractAgentMessageText(
                from: payload["content"] ?? payload["message"] ?? payload["text"] ?? resolved.payload
            ) {
                return ([["type": "text", "text": text]], runId)
            }
            return ([], runId)

        case "agent.thought", "agent.thought.chunk", "thinking", "reasoning":
            if let text = claudeExtractAgentMessageText(
                from: payload["content"] ?? payload["message"] ?? payload["text"] ?? resolved.payload
            ) {
                return ([["type": "thinking", "text": text]], runId)
            }
            return ([], runId)

        case "tool.call", "tool.call.update":
            return parseClaudeToolCallEvent(payload: payload, fallbackId: messageId, runId: runId)

        default:
            return nil
        }
    }

    private func parseClaudeToolCallEvent(
        payload: [String: Any],
        fallbackId: String?,
        runId: String?
    ) -> (blocks: [[String: Any]], runId: String?) {
        let toolCallId = claudeFirstNonEmptyString([
            payload["toolCallId"],
            payload["tool_call_id"],
            payload["callId"],
            payload["call_id"],
            payload["id"],
            fallbackId
        ]) ?? UUID().uuidString

        let toolNameRaw = claudeFirstNonEmptyString([
            claudeNestedValue(payload, path: ["_meta", "claudeCode", "toolName"]),
            payload["toolName"],
            payload["name"],
            payload["kind"],
            payload["title"]
        ]) ?? "Tool"
        let toolName = CLIToolSemantics.canonicalToolName(toolNameRaw)

        let toolKind = claudeFirstNonEmptyString([
            payload["kind"],
            payload["toolKind"],
            payload["tool_kind"]
        ])

        let status = claudeToolStatus(payload["status"] ?? payload["state"])
        let rawInput = payload["rawInput"] ?? payload["input"] ?? payload["params"] ?? payload["arguments"] ?? payload["payload"]
        let rawOutput = payload["rawOutput"] ?? payload["output"] ?? payload["result"]
        let metaToolResponse = claudeNestedValue(payload, path: ["_meta", "claudeCode", "toolResponse"])
        let hasContent = ((payload["content"] as? [Any])?.isEmpty == false)

        // Metadata-only mid updates are not useful as cards.
        if status == nil, rawInput == nil, rawOutput == nil, !hasContent, metaToolResponse != nil {
            return ([], runId ?? toolCallId)
        }

        var blocks: [[String: Any]] = []
        var toolUse: [String: Any] = [
            "type": "tool_use",
            "toolUseId": toolCallId,
            "toolName": toolName,
            "toolInput": stringifyValue(rawInput ?? [:]) ?? "{}"
        ]
        if let toolKind {
            toolUse["toolKind"] = toolKind
        }
        if let description = claudeFirstNonEmptyString([payload["title"]]), !description.isEmpty {
            toolUse["description"] = description
        }
        blocks.append(toolUse)

        if status == .success || status == .error {
            let outputText = claudeToolResultText(from: payload)
            var toolResult: [String: Any] = [
                "type": "tool_result",
                "toolUseId": toolCallId,
                "toolName": toolName,
                "text": outputText,
                "isError": status == .error
            ]
            if let toolKind {
                toolResult["toolKind"] = toolKind
            }
            blocks.append(toolResult)
        }

        return (blocks, runId ?? toolCallId)
    }

    private func resolveClaudeACPEnvelope(
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

    private func claudeExtractAgentMessageText(from value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : text
        }

        if let dict = value as? [String: Any] {
            if let text = dict["text"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }
            if let text = dict["message"] as? String,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return text
            }

            if let content = dict["content"] {
                if let nested = claudeExtractAgentMessageText(from: content) {
                    return nested
                }
            }
            if let payload = dict["payload"] {
                if let nested = claudeExtractAgentMessageText(from: payload) {
                    return nested
                }
            }
        }

        if let list = value as? [Any] {
            for item in list {
                if let nested = claudeExtractAgentMessageText(from: item) {
                    return nested
                }
            }
        }

        return nil
    }

    private enum ClaudeToolStatus {
        case pending
        case running
        case success
        case error
    }

    private func claudeToolStatus(_ value: Any?) -> ClaudeToolStatus? {
        guard let raw = claudeFirstNonEmptyString([value])?.lowercased() else {
            return nil
        }
        if ["error", "failed", "failure", "aborted", "cancelled", "canceled", "denied"].contains(raw) {
            return .error
        }
        if ["completed", "complete", "done", "success", "ok"].contains(raw) {
            return .success
        }
        if ["running", "in_progress", "active", "started"].contains(raw) {
            return .running
        }
        if ["pending", "queued", "waiting"].contains(raw) {
            return .pending
        }
        return nil
    }

    private func claudeToolResultText(from payload: [String: Any]) -> String {
        if let rawOutput = payload["rawOutput"],
           let rendered = stringifyValue(rawOutput) {
            return rendered
        }
        if let result = payload["result"],
           let rendered = stringifyValue(result) {
            return rendered
        }
        if let output = payload["output"],
           let rendered = stringifyValue(output) {
            return rendered
        }
        if let text = payload["text"] as? String {
            return text
        }
        if let content = payload["content"] as? [Any] {
            let parts = content.compactMap { item -> String? in
                guard let dict = item as? [String: Any] else { return nil }
                if let text = dict["text"] as? String, !text.isEmpty {
                    return text
                }
                if let nested = dict["content"] as? [String: Any],
                   let text = nested["text"] as? String,
                   !text.isEmpty {
                    return text
                }
                return nil
            }
            if !parts.isEmpty {
                return parts.joined(separator: "\n")
            }
        }
        return ""
    }

    private func claudeNestedValue(_ root: [String: Any], path: [String]) -> Any? {
        guard let first = path.first else { return nil }
        if path.count == 1 {
            return root[first]
        }
        guard let nested = root[first] as? [String: Any] else {
            return nil
        }
        return claudeNestedValue(nested, path: Array(path.dropFirst()))
    }

    private func claudeFirstNonEmptyString(_ values: [Any?]) -> String? {
        for value in values {
            if let text = value as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
                continue
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
        }
        return nil
    }
}
