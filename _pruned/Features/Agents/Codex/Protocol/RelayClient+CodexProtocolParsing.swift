import Foundation

extension RelayClient {
    func isCodexSilentEnvelopeType(_ canonicalType: String) -> Bool {
        let silentTypes: Set<String> = [
            "runtime.metadata",
            "event.runtime.metadata",
            "available.commands.update",
            "current.mode.update",
            "config.option.update",
            "available_commands_update",
            "current_mode_update",
            "config_option_update",
            "token.count"
        ]
        return silentTypes.contains(canonicalType)
    }

    func normalizeCodexACPType(_ type: String) -> String {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return trimmed }
        let canonicalized = trimmed
            .replacingOccurrences(of: "/", with: ".")
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: "-", with: ".")
            .replacingOccurrences(of: #"\.+"#, with: ".", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !canonicalized.isEmpty else { return canonicalized }

        let prefixes = [
            "event.codex.event.",
            "codex.event.",
            "event.codex.",
            "codex."
        ]

        for prefix in prefixes where canonicalized.hasPrefix(prefix) {
            return String(canonicalized.dropFirst(prefix.count))
        }

        return canonicalized
    }

    func shouldSuppressCodexEventFallback(name: String) -> Bool {
        let normalized = normalizeCodexACPType(name)
        guard !normalized.isEmpty else { return false }

        let codexLikePrefixes = [
            "thread.",
            "turn.",
            "task.",
            "item.",
            "agent.",
            "model.",
            "exec.",
            "patch.",
            "mcp.",
            "web.",
            "account.",
            "context.",
            "session.",
            "collab.",
            "undo.",
            "view.",
            "stream.",
            "raw.",
            "windows.",
            "skills.",
            "remote.",
            "runtime."
        ]

        return codexLikePrefixes.contains { normalized.hasPrefix($0) }
    }

    func shouldSuppressProtocolEventText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let lowered = trimmed.lowercased()
        if lowered.contains("reasoning section break")
            || lowered.hasPrefix("reasoning section #") {
            return true
        }

        let canonical = canonicalACPEventType(trimmed)
        guard !canonical.isEmpty else { return false }

        let codexNormalized = normalizeCodexACPType(canonical)
        let eventNormalized = canonical.hasPrefix("event.")
            ? String(canonical.dropFirst("event.".count))
            : canonical

        let silentNames: Set<String> = [
            "status",
            "item.started",
            "item.completed",
            "runtime.metadata",
            "mcp.startup.complete",
            "mcp.startup.update",
            "thread.started",
            "thread.archived",
            "thread.unarchived",
            "thread.tokenusage.updated",
            "account.updated",
            "account.ratelimits.updated",
            "item.reasoning.summarypartadded"
        ]

        return silentNames.contains(canonical)
            || silentNames.contains(eventNormalized)
            || silentNames.contains(codexNormalized)
    }

    func preferredACPMessageIdentifier(from payload: [String: Any]) -> String? {
        firstNonEmptyString([
            payload["id"] as? String,
            payload["item_id"] as? String,
            payload["itemId"] as? String,
            payload["call_id"] as? String,
            payload["callId"] as? String,
            payload["turn_id"] as? String,
            payload["turnId"] as? String,
            payload["thread_id"] as? String,
            payload["threadId"] as? String
        ])
    }

    func preferredACPEventRunIdentifier(from payload: [String: Any], fallback: String?) -> String? {
        firstNonEmptyString([
            payload["turn_id"] as? String,
            payload["turnId"] as? String,
            payload["thread_id"] as? String,
            payload["threadId"] as? String,
            fallback
        ])
    }

    func firstNonEmptyString(_ values: [String?]) -> String? {
        for value in values {
            guard let value else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    func parseCodexEventFromEventWrapper(
        eventName: String,
        payload: [String: Any],
        messageId: String?,
        fallbackRunId: String?
    ) -> (blocks: [[String: Any]], runId: String?)? {
        let normalizedName = normalizeCodexACPType(eventName)
        let normalizedPayload = flattenCodexEventPayload(payload)
        let payloadMessageId = preferredACPMessageIdentifier(from: normalizedPayload)
            ?? preferredACPMessageIdentifier(from: payload)
            ?? messageId

        if let parsed = parseCodexEventEnvelope(
            type: normalizedName,
            data: normalizedPayload,
            messageId: payloadMessageId
        ) {
            return (parsed.blocks, parsed.runId ?? fallbackRunId ?? payloadMessageId)
        }

        if let parsed = parseCodexACPEvent(
            type: normalizedName,
            data: normalizedPayload,
            messageId: payloadMessageId
        ) {
            return (parsed.blocks, parsed.runId ?? fallbackRunId ?? payloadMessageId)
        }

        if let itemType = (normalizedPayload["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !itemType.isEmpty,
           let parsed = parseCodexThreadItem(
            type: itemType,
            data: normalizedPayload,
            messageId: payloadMessageId
           ) {
            return (parsed.blocks, parsed.runId ?? fallbackRunId ?? payloadMessageId)
        }

        if let nestedName = (payload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nestedName.isEmpty,
           let nestedPayload = payload["payload"] as? [String: Any] {
            return parseCodexEventFromEventWrapper(
                eventName: nestedName,
                payload: nestedPayload,
                messageId: payloadMessageId,
                fallbackRunId: fallbackRunId
            )
        }

        return nil
    }

    func flattenCodexEventPayload(_ payload: [String: Any]) -> [String: Any] {
        guard let msg = payload["msg"] as? [String: Any], !msg.isEmpty else {
            return payload
        }

        var flattened = payload
        for (key, value) in msg {
            flattened[key] = value
        }

        if flattened["event_wrapper_id"] == nil, let wrapperId = payload["id"] {
            flattened["event_wrapper_id"] = wrapperId
        }

        return flattened
    }

    func parseCodexACPEvent(
        type: String,
        data: [String: Any],
        messageId: String?
    ) -> (blocks: [[String: Any]], runId: String?)? {
        let runId = preferredACPEventRunIdentifier(from: data, fallback: messageId)
        let eventId = preferredACPMessageIdentifier(from: data) ?? UUID().uuidString
        let normalizedType = normalizeCodexACPType(type)

        switch normalizedType {
        case "status":
            // Keep status events available for state synchronization, but do not render cards.
            return ([], runId)

        case "task.started", "task.complete", "turn.started", "turn.completed", "turn.aborted", "item.started", "item.completed":
            // Codex turn lifecycle events are session metadata; do not render as task tool cards.
            return ([], runId)

        case "context.compacted", "thread.compacted":
            let summary = summarizeCodexACPEvent(type: normalizedType, data: data) ?? "会话上下文已压缩"
            return ([["type": "event", "text": summary]], runId)

        case "agent.message", "agent.message.delta", "agent.message.content.delta":
            let text: String? = {
                return extractCodexAgentMessageText(data)
            }()
            if let text,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ([["type": "text", "text": text]], runId)
            }
            return ([], runId)

        case "user.message":
            if let text = extractCodexAgentMessageText(data),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ([["type": "text", "text": text, "_role": "user"]], runId)
            }
            return ([], runId)

        case "agent.reasoning", "agent.reasoning.delta", "agent.reasoning.raw.content", "agent.reasoning.raw.content.delta", "reasoning.content.delta", "reasoning.raw.content.delta":
            if let text = (data["text"] as? String) ?? (data["delta"] as? String),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ([["type": "thinking", "text": text]], runId)
            }
            return ([], runId)

        case "agent.reasoning.section.break":
            // Section boundary markers are useful for protocol diagnostics,
            // but too noisy for end-user timeline rendering.
            return ([], runId)

        case "plan.delta":
            if let delta = data["delta"] as? String,
               !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ([["type": "event", "text": "Plan\n\(delta)"]], runId)
            }
            return ([], runId)

        case "plan.update", "turn.plan.updated":
            if let plan = data["plan"] {
                let payload = stringifyValue(plan) ?? ""
                if !payload.isEmpty {
                    return ([["type": "event", "text": "Plan Update\n\(payload)"]], runId)
                }
            }
            if let text = (data["text"] as? String) ?? (data["message"] as? String),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ([["type": "event", "text": "Plan Update\n\(text)"]], runId)
            }
            return ([], runId)

        case "exec.command.begin":
            let callId = firstNonEmptyString([
                data["call_id"] as? String,
                data["callId"] as? String,
                data["item_id"] as? String,
                data["itemId"] as? String,
                messageId
            ]) ?? eventId
            let semantic = codexExecSemantic(from: data)
            var input: [String: Any] = [
                "command": data["command"] as Any,
                "cwd": data["cwd"] as Any,
                "parsed_cmd": data["parsed_cmd"] as Any,
                "commandActions": data["command_actions"] ?? data["commandActions"] as Any,
                "source": data["source"] as Any
            ]
            if !semantic.operations.isEmpty {
                input["operations"] = semantic.operations
            }
            return ([[
                "type": "tool_use",
                "toolUseId": callId,
                "toolName": semantic.toolName,
                "toolInput": stringifyValue(input) ?? "{}",
                "toolKind": semantic.toolKind
            ]], runId ?? callId)

        case "item.commandexecution.requestapproval", "exec.approval.request":
            let approvalId = firstNonEmptyString([
                data["approval_id"] as? String,
                data["approvalId"] as? String,
                data["item_id"] as? String,
                data["itemId"] as? String,
                data["call_id"] as? String,
                data["callId"] as? String,
                messageId
            ]) ?? eventId
            let input: [String: Any] = [
                "command": data["command"] as Any,
                "cwd": data["cwd"] as Any,
                "reason": data["reason"] as Any,
                "commandActions": data["command_actions"] ?? data["commandActions"] as Any,
                "proposedExecpolicyAmendment": data["proposed_execpolicy_amendment"] ?? data["proposedExecpolicyAmendment"] as Any
            ]
            return ([[
                "type": "tool_use",
                "toolUseId": approvalId,
                "toolName": "Bash",
                "toolInput": stringifyValue(input) ?? "{}",
                "toolKind": "command",
                "permission": [
                    "id": approvalId,
                    "status": "pending",
                    "reason": data["reason"] as Any
                ]
            ]], runId ?? approvalId)

        case "exec.command.end":
            let callId = firstNonEmptyString([
                data["call_id"] as? String,
                data["callId"] as? String,
                data["item_id"] as? String,
                data["itemId"] as? String,
                messageId
            ]) ?? eventId
            let semantic = codexExecSemantic(from: data)
            let status = ((data["status"] as? String) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let exitCode = parseInt(data["exit_code"] ?? data["exitCode"])
            let failedStatusSet: Set<String> = [
                "failed",
                "error",
                "aborted",
                "cancelled",
                "canceled",
                "declined",
                "denied",
                "timeout",
                "timed_out"
            ]
            let isError = failedStatusSet.contains(status) || ((exitCode ?? 0) != 0)
            var payload: [String: Any] = [
                "status": status,
                "command": data["command"] as Any,
                "cwd": data["cwd"] as Any,
                "parsed_cmd": data["parsed_cmd"] as Any,
                "commandActions": data["command_actions"] ?? data["commandActions"] as Any,
                "source": data["source"] as Any,
                "process_id": data["process_id"] ?? data["processId"] as Any,
                "stdout": data["stdout"] as Any,
                "stderr": data["stderr"] as Any,
                "aggregated_output": data["aggregated_output"] ?? data["aggregatedOutput"] as Any,
                "formatted_output": data["formatted_output"] ?? data["formattedOutput"] as Any,
                "exit_code": data["exit_code"] ?? data["exitCode"] as Any,
                "duration": data["duration"] ?? data["durationMs"] as Any
            ]
            if !semantic.operations.isEmpty {
                payload["operations"] = semantic.operations
            }
            return ([[
                "type": "tool_result",
                "toolUseId": callId,
                "toolName": semantic.toolName,
                "text": stringifyValue(payload) ?? "",
                "isError": isError,
                "toolKind": semantic.toolKind
            ]], runId ?? callId)

        case "patch.apply.begin":
            let callId = firstNonEmptyString([
                data["call_id"] as? String,
                data["callId"] as? String,
                data["item_id"] as? String,
                data["itemId"] as? String,
                messageId
            ]) ?? eventId
            let changes = data["changes"]
            let updatedFiles = extractCodexUpdatedFiles(from: changes)
            let input: [String: Any] = [
                "auto_approved": data["auto_approved"] as Any,
                "changes": changes as Any,
                "updatedFiles": updatedFiles
            ]
            return ([[
                "type": "tool_use",
                "toolUseId": callId,
                "toolName": "CodexPatch",
                "toolInput": stringifyValue(input) ?? "{}",
                "toolKind": "file_edit"
            ]], runId ?? callId)

        case "item.filechange.requestapproval", "apply.patch.approval.request":
            let approvalId = firstNonEmptyString([
                data["approval_id"] as? String,
                data["approvalId"] as? String,
                data["call_id"] as? String,
                data["callId"] as? String,
                data["item_id"] as? String,
                data["itemId"] as? String,
                messageId
            ]) ?? eventId
            let input: [String: Any] = [
                "reason": data["reason"] as Any,
                "grant_root": data["grant_root"] ?? data["grantRoot"] as Any,
                "changes": data["changes"] as Any
            ]
            return ([[
                "type": "tool_use",
                "toolUseId": approvalId,
                "toolName": "CodexPatch",
                "toolInput": stringifyValue(input) ?? "{}",
                "toolKind": "file_edit",
                "permission": [
                    "id": approvalId,
                    "status": "pending",
                    "reason": data["reason"] as Any
                ]
            ]], runId ?? approvalId)

        case "patch.apply.end":
            let callId = firstNonEmptyString([
                data["call_id"] as? String,
                data["callId"] as? String,
                data["item_id"] as? String,
                data["itemId"] as? String,
                messageId
            ]) ?? eventId
            let status = ((data["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let success = data["success"] as? Bool
            let changes = data["changes"]
            let updatedFiles = extractCodexUpdatedFiles(from: changes)
            let payload: [String: Any] = [
                "status": status,
                "success": success as Any,
                "stdout": data["stdout"] as Any,
                "stderr": data["stderr"] as Any,
                "changes": changes as Any,
                "updatedFiles": updatedFiles
            ]
            return ([[
                "type": "tool_result",
                "toolUseId": callId,
                "toolName": "CodexPatch",
                "text": stringifyValue(payload) ?? "",
                "isError": success == false || status == "failed"
            ]], runId ?? callId)

        case "mcp.tool.call.begin":
            let callId = firstNonEmptyString([
                data["call_id"] as? String,
                data["callId"] as? String,
                data["item_id"] as? String,
                data["itemId"] as? String,
                messageId
            ]) ?? eventId
            let invocation = data["invocation"] as? [String: Any]
            let toolName = normalizeToolName((invocation?["tool"] as? String) ?? (data["tool"] as? String) ?? "McpTool")
            let input: [String: Any] = [
                "server": invocation?["server"] as Any,
                "tool": invocation?["tool"] as Any,
                "arguments": invocation?["arguments"] ?? data["arguments"] as Any
            ]
            return ([[
                "type": "tool_use",
                "toolUseId": callId,
                "toolName": toolName,
                "toolInput": stringifyValue(input) ?? "{}"
            ]], runId ?? callId)

        case "mcp.tool.call.end":
            let callId = firstNonEmptyString([
                data["call_id"] as? String,
                data["callId"] as? String,
                data["item_id"] as? String,
                data["itemId"] as? String,
                messageId
            ]) ?? eventId
            let invocation = data["invocation"] as? [String: Any]
            let toolName = normalizeToolName((invocation?["tool"] as? String) ?? (data["tool"] as? String) ?? "McpTool")
            let payload: [String: Any] = [
                "result": data["result"] as Any,
                "error": data["error"] as Any,
                "duration": data["duration"] as Any
            ]
            let hasError = data["error"] != nil
            return ([[
                "type": "tool_result",
                "toolUseId": callId,
                "toolName": toolName,
                "text": stringifyValue(payload) ?? "",
                "isError": hasError
            ]], runId ?? callId)

        case "web.search.begin":
            let callId = firstNonEmptyString([
                data["call_id"] as? String,
                data["callId"] as? String,
                data["item_id"] as? String,
                data["itemId"] as? String,
                messageId
            ]) ?? eventId
            let input: [String: Any] = ["query": data["query"] as Any]
            return ([[
                "type": "tool_use",
                "toolUseId": callId,
                "toolName": "WebSearch",
                "toolInput": stringifyValue(input) ?? "{}"
            ]], runId ?? callId)

        case "web.search.end":
            let callId = firstNonEmptyString([
                data["call_id"] as? String,
                data["callId"] as? String,
                data["item_id"] as? String,
                data["itemId"] as? String,
                messageId
            ]) ?? eventId
            let payload: [String: Any] = [
                "query": data["query"] as Any,
                "action": data["action"] as Any
            ]
            return ([[
                "type": "tool_result",
                "toolUseId": callId,
                "toolName": "WebSearch",
                "text": stringifyValue(payload) ?? "",
                "isError": false
            ]], runId ?? callId)

        case "item.commandexecution.outputdelta",
            "item.filechange.outputdelta",
            "item.mcptoolcall.progress",
            "item.commandexecution.terminalinteraction",
            "terminal.interaction":
            // High-frequency Codex progress/delta events: keep out of timeline.
            // Begin/end events already carry enough info for compact cards.
            return ([], runId)

        case "request.user.input", "elicitation.request", "dynamic.tool.call.request":
            let callId = firstNonEmptyString([
                data["call_id"] as? String,
                data["callId"] as? String,
                messageId
            ]) ?? eventId
            let input = stringifyValue(data["questions"] ?? data["arguments"] ?? data["message"]) ?? "{}"
            return ([[
                "type": "tool_use",
                "toolUseId": callId,
                "toolName": "request_user_input",
                "toolInput": input,
                "permission": [
                    "id": callId,
                    "status": "pending"
                ]
            ]], runId ?? callId)

        case "error", "stream.error":
            let text = stringifyValue(data["message"] ?? data["error"] ?? data["additional_details"]) ?? "Error"
            let toolId = runId ?? messageId ?? eventId
            return ([[
                "type": "tool_result",
                "toolUseId": toolId,
                "toolName": "codex.error",
                "text": text,
                "isError": true
            ]], runId ?? toolId)

        default:
            break
        }

        if normalizedType.hasPrefix("collab.")
            || normalizedType == "background.event"
            || normalizedType == "thread.name.updated"
            || normalizedType == "thread.rolled.back"
            || normalizedType == "model.reroute"
            || normalizedType == "model.rerouted"
            || normalizedType == "warning"
            || normalizedType == "deprecation.notice"
            || normalizedType == "config.warning"
            || normalizedType == "windows.worldwritable.warning"
            || normalizedType == "entered.review.mode"
            || normalizedType == "exited.review.mode"
            || normalizedType == "session.configured"
            || normalizedType == "mcp.startup.complete"
            || normalizedType == "mcp.startup.update"
            || normalizedType == "shutdown.complete"
            || normalizedType == "skills.update.available"
            || normalizedType == "remote.skill.downloaded"
            || normalizedType == "thread.tokenusage.updated"
            || normalizedType == "account.updated"
            || normalizedType == "account.ratelimits.updated"
            || normalizedType == "undo.started"
            || normalizedType == "undo.completed"
            || normalizedType == "view.image.tool.call"
            || normalizedType.hasSuffix(".response")
            || normalizedType == "raw.response.item" {
            let conciseSummaryWhitelist: Set<String> = [
                "thread.name.updated",
                "model.reroute",
                "model.rerouted",
                "warning",
                "config.warning",
                "deprecation.notice"
            ]
            if conciseSummaryWhitelist.contains(normalizedType),
               let summary = summarizeCodexACPEvent(type: normalizedType, data: data) {
                return ([["type": "event", "text": summary]], runId)
            }
            return ([], runId)
        }

        return nil
    }

    func summarizeCodexACPEvent(type: String, data: [String: Any]) -> String? {
        switch type {
        case "thread.name.updated":
            if let name = data["thread_name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Thread name updated: \(name)"
            }
            return "Thread name updated"
        case "thread.rolled.back":
            return "Thread rolled back"
        case "context.compacted", "thread.compacted":
            return "会话上下文已压缩"
        case "model.reroute", "model.rerouted":
            let fromModel = (data["from_model"] as? String) ?? "unknown"
            let toModel = (data["to_model"] as? String) ?? "unknown"
            let reason = (data["reason"] as? String) ?? ""
            if reason.isEmpty {
                return "Model rerouted: \(fromModel) -> \(toModel)"
            }
            return "Model rerouted: \(fromModel) -> \(toModel) (\(reason))"
        case "warning", "config.warning":
            return (data["message"] as? String) ?? "Warning"
        case "deprecation.notice":
            return (data["message"] as? String) ?? "Deprecation notice"
        case "entered.review.mode":
            return "Entered review mode"
        case "exited.review.mode":
            return "Exited review mode"
        case "undo.started":
            return "Undo started"
        case "undo.completed":
            return "Undo completed"
        case "view.image.tool.call":
            if let path = data["path"] as? String, !path.isEmpty {
                return "View image: \(path)"
            }
            return "View image"
        default:
            break
        }

        if let message = (data["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }

        if let payload = stringifyValue(data),
           !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let compact = payload.count > 600 ? String(payload.prefix(600)) + "…" : payload
            return "[\(type)] \(compact)"
        }

        return "[\(type)]"
    }

    func parseCodexEventEnvelope(
        type: String,
        data: [String: Any],
        messageId: String?
    ) -> (blocks: [[String: Any]], runId: String?)? {
        let runId = preferredACPEventRunIdentifier(from: data, fallback: messageId)
        let normalizedType = normalizeCodexACPType(type)

        switch normalizedType {
        case "item.started", "item.updated", "item.completed":
            guard let item = data["item"] as? [String: Any],
                  let rawItemType = (item["type"] as? String)?.lowercased() else {
                return nil
            }
            let itemType = canonicalCodexTurnItemType(rawItemType)
            if let parsed = parseCodexThreadItem(type: itemType, data: item, messageId: (item["id"] as? String) ?? messageId) {
                return (parsed.blocks, runId ?? parsed.runId)
            }

            if itemType == "contextcompaction" {
                return ([["type": "event", "text": "Context compaction"]], runId ?? messageId)
            }

            let text = stringifyValue(item) ?? ""
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let compact = text.count > 800 ? String(text.prefix(800)) + "…" : text
                return ([["type": "event", "text": "[\(itemType)] \(compact)"]], runId ?? messageId)
            }
            return ([], runId)

        case "turn.failed":
            let text = stringifyValue(data["error"] ?? data["message"]) ?? "Turn failed"
            let id = runId ?? messageId ?? UUID().uuidString
            return ([[
                "type": "tool_result",
                "toolUseId": id,
                "toolName": "codex.turn",
                "text": text,
                "isError": true
            ]], id)

        case "error":
            let text = stringifyValue(data["message"] ?? data["error"]) ?? "Thread error"
            let id = runId ?? messageId ?? UUID().uuidString
            return ([[
                "type": "tool_result",
                "toolUseId": id,
                "toolName": "codex.error",
                "text": text,
                "isError": true
            ]], id)

        case "turn.started":
            let turnId = runId ?? messageId ?? UUID().uuidString
            // Turn lifecycle is not a tool invocation; keep chat timeline clean.
            return ([], turnId)

        case "turn.completed":
            let turnId = runId ?? messageId ?? UUID().uuidString
            // Turn lifecycle is not a tool invocation; errors are handled by `turn.failed` / `error`.
            return ([], turnId)

        case "thread.started", "thread.archived", "thread.unarchived":
            return ([], runId)

        default:
            return nil
        }
    }

    func parseCodexThreadItem(
        type: String,
        data: [String: Any],
        messageId: String?
    ) -> (blocks: [[String: Any]], runId: String?)? {
        let itemId = (data["id"] as? String) ?? messageId ?? UUID().uuidString
        let itemType = canonicalCodexTurnItemType(type)

        switch itemType {
        case "usermessage":
            if let text = extractCodexAgentMessageText(data),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return ([["type": "text", "text": text, "_role": "user"]], itemId)
            }
            return nil

        case "agentmessage":
            if let text = extractCodexAgentMessageText(data), !text.isEmpty {
                return ([["type": "text", "text": text]], itemId)
            }
            return nil

        case "plan":
            if let text = data["text"] as? String, !text.isEmpty {
                return ([["type": "event", "text": "Plan\n\(text)"]], itemId)
            }
            return nil

        case "reasoning":
            if let text = extractCodexReasoningText(data), !text.isEmpty {
                return ([["type": "thinking", "text": text]], itemId)
            }
            return nil

        case "commandexecution", "command_execution":
            let toolId = itemId
            if let changePayload = codexFileChangePayload(from: data) {
                let toolName = "CodexPatch"
                let status = (data["status"] as? String)?.lowercased() ?? ""
                let updatedFiles = extractCodexUpdatedFiles(from: changePayload)
                var blocks: [[String: Any]] = [[
                    "type": "tool_use",
                    "toolUseId": toolId,
                    "toolName": toolName,
                    "toolInput": stringifyValue([
                        "source": data["command"] as Any,
                        "status": status,
                        "changes": changePayload,
                        "updatedFiles": updatedFiles
                    ]) ?? "{}"
                ]]

                if status == "completed" || status == "failed" || status == "declined" {
                    let resultPayload: [String: Any] = [
                        "status": status,
                        "success": status == "completed",
                        "changes": changePayload,
                        "updatedFiles": updatedFiles,
                        "stdout": data["aggregatedOutput"] ?? data["output"] as Any,
                        "stderr": data["error"] as Any,
                        "auto_approved": data["auto_approved"] as Any,
                    ]
                    blocks.append([
                        "type": "tool_result",
                        "toolUseId": toolId,
                        "toolName": toolName,
                        "text": stringifyValue(resultPayload) ?? status,
                        "isError": status == "failed"
                    ])
                }
                return (blocks, toolId)
            }

            let command = data["command"] as? String
            let semantic = codexExecSemantic(from: data)
            var input: [String: Any] = [
                "command": command as Any,
                "cwd": data["cwd"] as Any,
                "processId": data["processId"] as Any,
                "commandActions": data["commandActions"] as Any
            ]
            if !semantic.operations.isEmpty {
                input["operations"] = semantic.operations
            }

            var blocks: [[String: Any]] = [[
                "type": "tool_use",
                "toolUseId": toolId,
                "toolName": semantic.toolName,
                "toolInput": stringifyValue(input) ?? "{}",
                "toolKind": semantic.toolKind
            ]]

            let status = (data["status"] as? String)?.lowercased() ?? ""
            if status == "completed" || status == "failed" || status == "declined" {
                var resultPayload: [String: Any] = [
                    "status": status,
                    "success": status == "completed",
                    "aggregatedOutput": data["aggregatedOutput"] as Any,
                    "stdout": data["stdout"] as Any,
                    "stderr": data["stderr"] as Any,
                    "exitCode": data["exitCode"] as Any,
                    "durationMs": data["durationMs"] as Any
                ]
                if !semantic.operations.isEmpty {
                    resultPayload["operations"] = semantic.operations
                }
                blocks.append([
                    "type": "tool_result",
                    "toolUseId": toolId,
                    "toolName": semantic.toolName,
                    "text": stringifyValue(resultPayload) ?? "",
                    "isError": status == "failed",
                    "toolKind": semantic.toolKind
                ])
            }
            return (blocks, toolId)

        case "filechange", "file_change":
            let toolId = itemId
            let toolName = "CodexPatch"
            let changesPayload = data["changes"] ?? codexFileChangePayload(from: data)
            let updatedFiles = extractCodexUpdatedFiles(from: changesPayload)
            var blocks: [[String: Any]] = [[
                "type": "tool_use",
                "toolUseId": toolId,
                "toolName": toolName,
                "toolInput": stringifyValue([
                    "changes": changesPayload as Any,
                    "updatedFiles": updatedFiles
                ]) ?? "{}"
            ]]

            let status = (data["status"] as? String)?.lowercased() ?? ""
            if status == "completed" || status == "failed" || status == "declined" {
                let outputPayload: [String: Any] = [
                    "status": status,
                    "success": status == "completed",
                    "changes": changesPayload as Any,
                    "updatedFiles": updatedFiles,
                    "stdout": data["output"] as Any,
                    "stderr": data["error"] as Any
                ]
                blocks.append([
                    "type": "tool_result",
                    "toolUseId": toolId,
                    "toolName": toolName,
                    "text": stringifyValue(outputPayload) ?? status,
                    "isError": status == "failed"
                ])
            }
            return (blocks, toolId)

        case "mcptoolcall", "mcp_tool_call":
            let toolId = itemId
            let server = (data["server"] as? String) ?? "mcp"
            let tool = (data["tool"] as? String) ?? "tool"
            let toolName = normalizeToolName(tool)
            let input: [String: Any] = [
                "server": server,
                "tool": tool,
                "arguments": data["arguments"] as Any
            ]
            var blocks: [[String: Any]] = [[
                "type": "tool_use",
                "toolUseId": toolId,
                "toolName": toolName,
                "toolInput": stringifyValue(input) ?? "{}"
            ]]

            let status = (data["status"] as? String)?.lowercased() ?? ""
            if status == "completed" || status == "failed" {
                let output = stringifyValue(data["result"] ?? data["error"]) ?? ""
                blocks.append([
                    "type": "tool_result",
                    "toolUseId": toolId,
                    "toolName": toolName,
                    "text": output,
                    "isError": status == "failed"
                ])
            }
            return (blocks, toolId)

        case "websearch", "web_search":
            let toolId = itemId
            let query = (data["query"] as? String) ?? ""
            let input: [String: Any] = [
                "query": query,
                "action": data["action"] as Any
            ]
            return ([[
                "type": "tool_use",
                "toolUseId": toolId,
                "toolName": "WebSearch",
                "toolInput": stringifyValue(input) ?? "{}"
            ]], toolId)

        case "todolist", "todo_list":
            let toolId = itemId
            var blocks: [[String: Any]] = [[
                "type": "tool_use",
                "toolUseId": toolId,
                "toolName": "TodoWrite",
                "toolInput": "{}"
            ]]
            blocks.append([
                "type": "tool_result",
                "toolUseId": toolId,
                "toolName": "TodoWrite",
                "text": stringifyValue(data["items"] ?? []) ?? "[]",
                "isError": false
            ])
            return (blocks, toolId)

        case "error":
            let text = (data["message"] as? String) ?? "Error"
            return ([[
                "type": "tool_result",
                "toolUseId": itemId,
                "toolName": "codex.error",
                "text": text,
                "isError": true
            ]], itemId)

        case "collabagenttoolcall", "collab_agent_tool_call":
            let toolId = itemId
            let tool = (data["tool"] as? String) ?? "Task"
            let input: [String: Any] = [
                "senderThreadId": data["senderThreadId"] as Any,
                "receiverThreadIds": data["receiverThreadIds"] as Any,
                "prompt": data["prompt"] as Any,
                "agentsStates": data["agentsStates"] as Any
            ]
            var blocks: [[String: Any]] = [[
                "type": "tool_use",
                "toolUseId": toolId,
                "toolName": tool,
                "toolInput": stringifyValue(input) ?? "{}"
            ]]
            let status = (data["status"] as? String)?.lowercased() ?? ""
            if status == "completed" || status == "failed" {
                blocks.append([
                    "type": "tool_result",
                    "toolUseId": toolId,
                    "toolName": tool,
                    "text": stringifyValue(data["agentsStates"] ?? [:]) ?? "",
                    "isError": status == "failed"
                ])
            }
            return (blocks, toolId)

        default:
            return nil
        }
    }

    func extractCodexUserMessageText(_ data: [String: Any]) -> String? {
        if let nested = data["msg"] as? [String: Any],
           let text = extractCodexUserMessageText(nested),
           !text.isEmpty {
            return text
        }

        if let direct = (data["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !direct.isEmpty {
            return direct
        }
        if let message = (data["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        let textParts = extractCodexContentTexts(data["content"])
        guard !textParts.isEmpty else { return nil }
        return textParts.joined(separator: "\n")
    }

    func extractCodexAgentMessageText(_ data: [String: Any]) -> String? {
        if let nested = data["msg"] as? [String: Any],
           let text = extractCodexAgentMessageText(nested),
           !text.isEmpty {
            return text
        }

        if let delta = (data["delta"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !delta.isEmpty {
            return delta
        }
        if let direct = (data["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !direct.isEmpty {
            return direct
        }
        if let message = (data["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !message.isEmpty {
            return message
        }
        let textParts = extractCodexContentTexts(data["content"])
        guard !textParts.isEmpty else { return nil }
        return textParts.joined(separator: "\n")
    }

    func extractCodexContentTexts(_ value: Any?) -> [String] {
        guard let parts = value as? [[String: Any]], !parts.isEmpty else {
            return []
        }

        var texts: [String] = []
        texts.reserveCapacity(parts.count)
        for part in parts {
            if let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                texts.append(text)
                continue
            }

            if let delta = (part["delta"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !delta.isEmpty {
                texts.append(delta)
                continue
            }

            if let content = part["content"] as? [String: Any],
               let nestedText = (content["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !nestedText.isEmpty {
                texts.append(nestedText)
                continue
            }

            if let content = (part["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !content.isEmpty {
                texts.append(content)
            }
        }
        return texts
    }

    private struct CodexExecSemantic {
        let toolName: String
        let toolKind: String
        let operations: [[String: Any]]
    }

    private func codexExecSemantic(from data: [String: Any]) -> CodexExecSemantic {
        let actions = codexCommandActions(from: data)
        let exploreActions = codexExploreEligibleActions(from: actions)
        let operations = codexParallelOperations(from: actions)
        let source = codexCommandSource(from: data)
        let isUserShell = source == "user_shell"
        let actionTypes = actions.compactMap { codexNormalizedCommandActionType(from: $0) }

        if !exploreActions.isEmpty, !isUserShell {
            return CodexExecSemantic(
                toolName: "ParallelToolUse",
                toolKind: "parallel_dispatch",
                operations: codexParallelOperations(from: exploreActions)
            )
        }

        if !actionTypes.isEmpty,
           actionTypes.allSatisfy({ $0 == "read" }) {
            return CodexExecSemantic(
                toolName: "Read",
                toolKind: "read",
                operations: operations
            )
        }

        if !actionTypes.isEmpty,
           actionTypes.allSatisfy({ $0 == "search" || $0 == "list_files" }) {
            return CodexExecSemantic(
                toolName: "Glob",
                toolKind: "glob",
                operations: operations
            )
        }

        return CodexExecSemantic(
            toolName: "Bash",
            toolKind: "command",
            operations: operations
        )
    }

    private func codexCommandActions(from data: [String: Any]) -> [[String: Any]] {
        let directKeys = ["parsed_cmd", "parsedCmd", "command_actions", "commandActions", "actions"]
        for key in directKeys {
            if let actions = codexCommandActionArray(from: data[key]) {
                return actions
            }
        }

        for containerKey in ["input", "params", "parameters", "payload", "data"] {
            guard let nested = data[containerKey] as? [String: Any] else { continue }
            for key in directKeys {
                if let actions = codexCommandActionArray(from: nested[key]) {
                    return actions
                }
            }
        }

        return []
    }

    private func codexCommandActionArray(from value: Any?) -> [[String: Any]]? {
        if let actions = value as? [[String: Any]], !actions.isEmpty {
            return actions
        }
        if let list = value as? [Any] {
            let actions = list.compactMap { $0 as? [String: Any] }
            return actions.isEmpty ? nil : actions
        }
        return nil
    }

    private func codexCommandSource(from data: [String: Any]) -> String {
        let raw = (
            firstNonEmptyString([
                data["source"] as? String,
                data["command_source"] as? String,
                data["commandSource"] as? String
            ]) ?? ""
        )
        return raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
    }

    private func codexNormalizedCommandActionType(from action: [String: Any]) -> String? {
        let rawType = firstNonEmptyString([
            action["type"] as? String,
            action["kind"] as? String,
            action["action"] as? String
        ])
        guard let rawType else { return nil }
        let normalized = rawType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
        switch normalized {
        case "list", "listfiles":
            return "list_files"
        default:
            return normalized
        }
    }

    private func codexIsExploreActionType(_ type: String) -> Bool {
        type == "read" || type == "list_files" || type == "search"
    }

    private func codexExploreEligibleActions(from actions: [[String: Any]]) -> [[String: Any]] {
        guard !actions.isEmpty else { return [] }

        var eligible: [[String: Any]] = []
        var hasExplore = false

        for action in actions {
            guard let type = codexNormalizedCommandActionType(from: action) else {
                if codexIsIgnorableUnknownAction(action) {
                    continue
                }
                return []
            }

            if codexIsExploreActionType(type) {
                hasExplore = true
                eligible.append(action)
                continue
            }

            if codexIsIgnorableUnknownAction(action) {
                continue
            }

            return []
        }

        return hasExplore ? eligible : []
    }

    private func codexIsIgnorableUnknownAction(_ action: [String: Any]) -> Bool {
        let type = codexNormalizedCommandActionType(from: action)
        if let type, type != "unknown", type != "command", type != "generic" {
            return false
        }

        let command = firstNonEmptyString([
            action["cmd"] as? String,
            action["command"] as? String,
            action["script"] as? String
        ])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if command.isEmpty {
            return true
        }

        return codexIsBenignExploreCompanionCommand(command)
    }

    private func codexIsBenignExploreCompanionCommand(_ command: String) -> Bool {
        let normalized = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return true }

        let exactAllowed: Set<String> = [
            "pwd",
            "true",
            ":",
            "echo",
            "echo ---"
        ]
        if exactAllowed.contains(normalized) {
            return true
        }

        if normalized.hasPrefix("cd ")
            || normalized.hasPrefix("echo ")
            || normalized.hasPrefix("printf ") {
            return true
        }

        return false
    }

    private func codexParallelOperations(from actions: [[String: Any]]) -> [[String: Any]] {
        actions.compactMap { action in
            guard let type = codexNormalizedCommandActionType(from: action) else { return nil }
            var operation: [String: Any] = ["type": type]
            if let cmd = firstNonEmptyString([
                action["cmd"] as? String,
                action["command"] as? String,
                action["script"] as? String
            ]) {
                operation["cmd"] = cmd
            }
            if let path = firstNonEmptyString([
                action["path"] as? String,
                action["file"] as? String,
                action["filePath"] as? String
            ]) {
                operation["path"] = path
            }
            if let name = firstNonEmptyString([
                action["name"] as? String,
                action["target"] as? String
            ]) {
                operation["name"] = name
            }
            if let query = firstNonEmptyString([
                action["query"] as? String,
                action["pattern"] as? String,
                action["keyword"] as? String
            ]) {
                operation["query"] = query
            }
            return operation
        }
    }

    func canonicalCodexTurnItemType(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "/", with: "")
    }

    func extractCodexReasoningText(_ data: [String: Any]) -> String? {
        var lines: [String] = []
        if let summary = data["summary"] as? [String] {
            lines.append(contentsOf: summary.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        }
        if let content = data["content"] as? [String] {
            lines.append(contentsOf: content.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        } else if let content = data["content"] as? [[String: Any]] {
            for part in content {
                if let text = (part["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    lines.append(text)
                    continue
                }
                if let text = (part["delta"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    lines.append(text)
                    continue
                }
                if let nested = part["content"] as? [String: Any],
                   let text = (nested["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !text.isEmpty {
                    lines.append(text)
                }
            }
        } else if let text = data["text"] as? String, !text.isEmpty {
            lines.append(text)
        }
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n")
    }

    func extractCodexUpdatedFiles(from value: Any?) -> [String] {
        guard let value else { return [] }

        var queue: [Any] = [value]
        var cursor = 0
        var scanned = 0
        let maxNodes = 2048

        var seen = Set<String>()
        var results: [String] = []

        while cursor < queue.count && scanned < maxNodes {
            let current = queue[cursor]
            cursor += 1
            scanned += 1

            if let dict = current as? [String: Any] {
                let path = firstNonEmptyString([
                    dict["path"] as? String,
                    dict["file_path"] as? String,
                    dict["filePath"] as? String,
                    dict["filename"] as? String
                ])
                if let path {
                    let kind = firstNonEmptyString([
                        dict["kind"] as? String,
                        dict["changeType"] as? String,
                        dict["change_type"] as? String,
                        dict["status"] as? String
                    ])
                    let entry = "\(codexUpdatedFilePrefix(kind)) \(path)"
                    if seen.insert(entry).inserted {
                        results.append(entry)
                    }
                }

                for (key, nested) in dict {
                    if path == nil,
                       let nestedString = nested as? String,
                       !nestedString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       key.contains("/") || key.contains(".") {
                        let entry = "~ \(key)"
                        if seen.insert(entry).inserted {
                            results.append(entry)
                        }
                    }
                    queue.append(nested)
                }
                continue
            }

            if let array = current as? [Any] {
                for nested in array {
                    queue.append(nested)
                }
                continue
            }

            if let raw = current as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
                   let data = trimmed.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data) {
                    queue.append(json)
                }
            }
        }

        return results.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func codexUpdatedFilePrefix(_ kind: String?) -> String {
        let normalized = (kind ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if normalized.contains("add") || normalized.contains("create") || normalized.contains("new") {
            return "+"
        }
        if normalized.contains("delete") || normalized.contains("remove") {
            return "-"
        }
        if normalized.contains("move") || normalized.contains("rename") {
            return ">"
        }
        return "~"
    }


}
