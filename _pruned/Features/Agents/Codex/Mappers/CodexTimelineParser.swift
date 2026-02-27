import Foundation

struct CodexTimelineParser: AgentTimelineParser {
    let agentType: AgentChannelType = .codex

    func buildItems(from rawEvent: AgentRawEventEnvelope) -> [AgentTimelineItem] {
        DefaultRawTimelineParser(agentType: agentType).buildItems(from: rawEvent)
    }
}

struct CodexExploreSegment: Identifiable {
    let id: String
    let tools: [CLIMessage.ToolUse]
    let beforeMessageIndex: Int?
}

enum CodexExploreAggregation {
    static func segments(
        groupId: String,
        runtimeMessages: [CLIMessage],
        latestToolMessageIndexById: [String: Int],
        mergedToolStateById: [String: CLIMessage.ToolUse]
    ) -> [CodexExploreSegment] {
        var segments: [CodexExploreSegment] = []
        var pendingTools: [CLIMessage.ToolUse] = []
        var pendingIDs = Set<String>()
        var sequence = 0

        for (index, message) in runtimeMessages.enumerated() {
            let kinds = visibleToolKinds(
                message: message,
                messageIndex: index,
                latestToolMessageIndexById: latestToolMessageIndexById,
                mergedToolStateById: mergedToolStateById
            )
            let shouldFlushBeforeMessage = hasRenderableText(in: message) || !kinds.other.isEmpty

            if shouldFlushBeforeMessage, !pendingTools.isEmpty {
                segments.append(
                    CodexExploreSegment(
                        id: "explore-\(groupId)-\(sequence)",
                        tools: pendingTools,
                        beforeMessageIndex: index
                    )
                )
                sequence += 1
                pendingTools.removeAll(keepingCapacity: true)
                pendingIDs.removeAll(keepingCapacity: true)
            }

            for tool in kinds.explore where pendingIDs.insert(tool.id).inserted {
                pendingTools.append(tool)
            }
        }

        if !pendingTools.isEmpty {
            segments.append(
                CodexExploreSegment(
                    id: "explore-\(groupId)-\(sequence)",
                    tools: pendingTools,
                    beforeMessageIndex: nil
                )
            )
        }

        return segments
    }

    private static func visibleToolKinds(
        message: CLIMessage,
        messageIndex: Int,
        latestToolMessageIndexById: [String: Int],
        mergedToolStateById: [String: CLIMessage.ToolUse]
    ) -> (explore: [CLIMessage.ToolUse], other: [CLIMessage.ToolUse]) {
        let sourceTools = message.toolUse ?? []
        var seen = Set<String>()
        var explore: [CLIMessage.ToolUse] = []
        var other: [CLIMessage.ToolUse] = []

        for tool in sourceTools {
            guard latestToolMessageIndexById[tool.id] == messageIndex else { continue }
            let resolved = mergedToolStateById[tool.id] ?? tool
            guard seen.insert(resolved.id).inserted else { continue }
            if isExploreTool(resolved) {
                explore.append(resolved)
            } else {
                other.append(resolved)
            }
        }

        return (explore: explore, other: other)
    }

    private static func hasRenderableText(in message: CLIMessage) -> Bool {
        if message.role == .user {
            return !message.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return message.content.contains { block in
            guard block.type == .text else { return false }
            guard let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !text.isEmpty
        }
    }

    private static func isExploreTool(_ tool: CLIMessage.ToolUse) -> Bool {
        let semantic = CLIToolSemantics.classifyToolName(tool.name)
        if semantic == .parallelDispatch || semantic == .read || semantic == .glob {
            return true
        }

        // Codex may emit exec_command tools as generic "Bash"/"Command" names.
        // Prefer structured parsed_cmd/operations extraction before any string fallback.
        if semantic == .command || semantic == .generic || semantic == .protocolFallback {
            if containsExploreOperation(in: tool) {
                return true
            }
            if isExploreCommand(ToolCardSemanticHelpers.parseBashInput(tool.input)?.command) {
                return true
            }
            if isExploreCommand(ToolCardSemanticHelpers.extractCommand(from: tool.input)) {
                return true
            }
            if isExploreCommand(ToolCardSemanticHelpers.parseBashOutput(tool.output)?.command) {
                return true
            }
        }

        return false
    }

    private static func containsExploreOperation(in tool: CLIMessage.ToolUse) -> Bool {
        let operations = CodexToolPayloadResolver.exploreOperations(for: tool)
        guard !operations.isEmpty else { return false }
        return operations.allSatisfy { op in
            let title = op.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return title == "read" || title == "search" || title == "list"
        }
    }

    private static func isExploreCommand(_ command: String?) -> Bool {
        guard let command else { return false }
        switch ToolCardSemanticHelpers.classifyCommandSubtype(command) {
        case .search, .read, .list:
            return true
        case .generic:
            return false
        }
    }
}

enum CodexToolPayloadResolver {
    static func exploreOperations(for tool: CLIMessage.ToolUse) -> [ParallelDispatchOperationSnapshot] {
        var operations: [ParallelDispatchOperationSnapshot] = []
        operations.append(contentsOf: ToolCardSemanticHelpers.parseParallelDispatchOperations(tool.input))
        operations.append(contentsOf: ToolCardSemanticHelpers.parseParallelDispatchOperations(tool.output))

        if operations.isEmpty {
            if let ref = tool.inputPayloadRef, let sidecar = readSidecar(ref: ref) {
                operations.append(contentsOf: ToolCardSemanticHelpers.parseParallelDispatchOperations(sidecar))
            }
        }
        if operations.isEmpty {
            if let ref = tool.outputPayloadRef, let sidecar = readSidecar(ref: ref) {
                operations.append(contentsOf: ToolCardSemanticHelpers.parseParallelDispatchOperations(sidecar))
            }
        }

        var seen = Set<String>()
        var deduped: [ParallelDispatchOperationSnapshot] = []
        for op in operations {
            let key = "\(op.title.lowercased())|\((op.detail ?? "").lowercased())"
            if seen.insert(key).inserted {
                deduped.append(op)
            }
        }
        return deduped
    }

    static func primaryCommand(for tool: CLIMessage.ToolUse) -> String? {
        let payloadCandidates = payloadCandidates(for: tool)
        for raw in payloadCandidates {
            if let cmd = firstParsedCommand(from: raw) {
                return cmd
            }
        }

        // Fallback to generic command extraction only when parsed_cmd is unavailable.
        for raw in payloadCandidates {
            if let cmd = ToolCardSemanticHelpers.parseBashInput(raw)?.command,
               !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !cmd.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                return cmd
            }
            if let cmd = ToolCardSemanticHelpers.extractCommand(from: raw),
               !cmd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !cmd.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") {
                return cmd
            }
        }

        return nil
    }

    private static func payloadCandidates(for tool: CLIMessage.ToolUse) -> [String] {
        var candidates: [String] = []
        if let input = tool.input?.trimmingCharacters(in: .whitespacesAndNewlines), !input.isEmpty {
            candidates.append(input)
        }
        if let output = tool.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
            candidates.append(output)
        }
        if let ref = tool.inputPayloadRef, let sidecar = readSidecar(ref: ref),
           !sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(sidecar)
        }
        if let ref = tool.outputPayloadRef, let sidecar = readSidecar(ref: ref),
           !sidecar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates.append(sidecar)
        }
        return candidates
    }

    private static func firstParsedCommand(from raw: String) -> String? {
        guard let json = ToolUseJSONParser.parseJSON(raw) else { return nil }
        guard let root = json as? [String: Any] else { return nil }
        return firstParsedCommand(in: root)
    }

    private static func firstParsedCommand(in dict: [String: Any]) -> String? {
        let actionKeys = ["parsed_cmd", "parsedCmd", "command_actions", "commandActions", "actions"]
        for key in actionKeys {
            if let command = firstParsedCommand(in: dict[key]) {
                return command
            }
        }

        for key in ["input", "payload", "data", "params", "parameters", "request"] {
            guard let nested = dict[key] as? [String: Any] else { continue }
            if let command = firstParsedCommand(in: nested) {
                return command
            }
        }

        return nil
    }

    private static func firstParsedCommand(in value: Any?) -> String? {
        if let list = value as? [[String: Any]] {
            for item in list {
                let candidate = (item["cmd"] as? String)
                    ?? (item["command"] as? String)
                    ?? (item["script"] as? String)
                let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
            return nil
        }

        if let list = value as? [Any] {
            for item in list {
                if let command = firstParsedCommand(in: item) {
                    return command
                }
            }
            return nil
        }

        if let dict = value as? [String: Any] {
            return firstParsedCommand(in: dict)
        }

        return nil
    }

    private static func readSidecar(ref: String) -> String? {
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
