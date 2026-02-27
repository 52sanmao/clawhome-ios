import Foundation

enum ClaudeACPMessageNormalizer {
    static func normalize(_ messages: [CLIMessage]) -> [CLIMessage] {
        messages.map(normalizeMessage)
    }

    private static func normalizeMessage(_ message: CLIMessage) -> CLIMessage {
        guard message.role == .assistant else { return message }
        guard var tools = message.toolUse, !tools.isEmpty else { return message }

        var extractedTexts: [String] = []
        var droppedToolIDs = Set<String>()

        for tool in tools {
            guard isProtocolMessageTool(tool) else { continue }
            guard let text = extractAggregatedMessageText(from: tool) else { continue }

            droppedToolIDs.insert(tool.id)
            if !text.isEmpty {
                extractedTexts.append(text)
            }
        }

        guard !droppedToolIDs.isEmpty else { return message }

        tools.removeAll { droppedToolIDs.contains($0.id) }
        var nextContent = message.content
        let hasRenderableText = message.content.contains { block in
            guard block.type == .text else { return false }
            guard let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !text.isEmpty
        }

        if !hasRenderableText, !extractedTexts.isEmpty {
            let mergedText = extractedTexts.joined(separator: "\n")
            nextContent.append(
                CLIMessage.ContentBlock(
                    type: .text,
                    text: mergedText,
                    toolUseId: nil,
                    toolName: nil,
                    toolInput: nil,
                    uuid: nil,
                    parentUUID: nil
                )
            )
        }

        return CLIMessage(
            id: message.id,
            role: message.role,
            content: nextContent,
            timestamp: message.timestamp,
            toolUse: tools.isEmpty ? nil : tools,
            rawMessageId: message.rawMessageId,
            rawSeq: message.rawSeq,
            runId: message.runId,
            parentRunId: message.parentRunId,
            isSidechain: message.isSidechain
        )
    }

    private static func isProtocolMessageTool(_ tool: CLIMessage.ToolUse) -> Bool {
        let key = tool.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard key.hasPrefix("protocol.") else { return false }

        if key == "protocol.message" || key == "protocol.agent.message" {
            return true
        }
        if key.hasSuffix(".message") {
            return true
        }
        return false
    }

    private static func extractAggregatedMessageText(from tool: CLIMessage.ToolUse) -> String? {
        if let text = parseMessageText(fromPayloadString: tool.input) {
            return text
        }
        if let text = parseMessageText(fromPayloadString: tool.output) {
            return text
        }
        return nil
    }

    private static func parseMessageText(fromPayloadString raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Fallback payload format: "[未适配协议事件] <type>\n<payload-json>"
        let marker = "[未适配协议事件]"
        let payloadText: String = {
            guard trimmed.hasPrefix(marker) else { return trimmed }
            let lines = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            if lines.count > 1 {
                return String(lines[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return trimmed
        }()

        guard let data = payloadText.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let dict = value as? [String: Any] else {
            return nil
        }

        let direct = nonEmptyString(dict["message"]) ?? nonEmptyString(dict["text"])
        if let direct {
            return direct
        }

        if let payload = dict["payload"] as? [String: Any] {
            if let nested = nonEmptyString(payload["message"]) ?? nonEmptyString(payload["text"]) {
                return nested
            }
            if let content = payload["content"] as? [String: Any],
               let nested = nonEmptyString(content["text"]) {
                return nested
            }
        }

        if let content = dict["content"] as? [String: Any],
           let nested = nonEmptyString(content["text"]) {
            return nested
        }

        return nil
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
