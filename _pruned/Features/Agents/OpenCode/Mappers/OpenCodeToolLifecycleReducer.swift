import Foundation

struct OpenCodeToolLifecycleProjection {
    let resolvedToolStateById: [String: CLIMessage.ToolUse]
    let suppressedToolIDs: Set<String>
}

enum OpenCodeToolLifecycleReducer {
    static func project(
        mergedToolStateById: [String: CLIMessage.ToolUse],
        latestToolMessageIndexById: [String: Int]
    ) -> OpenCodeToolLifecycleProjection {
        guard !mergedToolStateById.isEmpty else {
            return OpenCodeToolLifecycleProjection(
                resolvedToolStateById: mergedToolStateById,
                suppressedToolIDs: []
            )
        }

        var resolved = mergedToolStateById
        for (toolID, tool) in mergedToolStateById {
            var updated = tool
            if let derivedStatus = derivedLifecycleStatus(for: tool) {
                updated.status = derivedStatus
            }
            resolved[toolID] = updated
        }

        var suppressedToolIDs = Set<String>()
        let lifecycleComponents = buildBackgroundLifecycleComponents(
            resolvedTools: resolved
        )

        for ids in lifecycleComponents where ids.count > 1 {
            guard let keepID = preferredVisibleToolID(
                ids: ids,
                latestToolMessageIndexById: latestToolMessageIndexById,
                resolvedTools: resolved
            ) else {
                continue
            }

            if var keepTool = resolved[keepID] {
                let orderedIDs = ids.sorted { lhs, rhs in
                    let lhsIndex = latestToolMessageIndexById[lhs] ?? Int.min
                    let rhsIndex = latestToolMessageIndexById[rhs] ?? Int.min
                    if lhsIndex != rhsIndex {
                        return lhsIndex < rhsIndex
                    }
                    return lhs < rhs
                }

                let lifecycleTools = orderedIDs.compactMap { resolved[$0] }
                if let mergedOutput = mergeLifecycleText(
                    lifecycleTools.compactMap(\.output)
                ) {
                    keepTool.output = mergedOutput
                }

                if let mergedInput = mergeLifecycleText(
                    lifecycleTools.compactMap(\.input)
                ) {
                    keepTool.input = mergedInput
                }

                if let finalStatus = lifecycleTools.last?.status {
                    keepTool.status = finalStatus
                }

                keepTool.name = "BackgroundTask"
                resolved[keepID] = keepTool
            }

            for id in ids where id != keepID {
                suppressedToolIDs.insert(id)
            }
        }

        // OpenCode todo stream is a single evolving plan snapshot in one run.
        // Keep only the latest todo card and suppress historical duplicates.
        let todoIDs = resolved.compactMap { (toolID, tool) -> String? in
            CLIToolSemantics.classifyToolName(tool.name) == .todo ? toolID : nil
        }
        if todoIDs.count > 1,
           let keepID = preferredVisibleToolID(
            ids: todoIDs,
            latestToolMessageIndexById: latestToolMessageIndexById,
            resolvedTools: resolved
           ) {
            let orderedTodoIDs = todoIDs.sorted { lhs, rhs in
                let lhsIndex = latestToolMessageIndexById[lhs] ?? Int.min
                let rhsIndex = latestToolMessageIndexById[rhs] ?? Int.min
                if lhsIndex != rhsIndex {
                    return lhsIndex < rhsIndex
                }
                return lhs < rhs
            }
            let orderedTodoTools = orderedTodoIDs.compactMap { resolved[$0] }

            if var keepTool = resolved[keepID] {
                if keepTool.output?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                   let latestOutput = orderedTodoTools.reversed().compactMap(\.output).first(where: {
                       !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   }) {
                    keepTool.output = latestOutput
                }
                if keepTool.input?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true,
                   let latestInput = orderedTodoTools.reversed().compactMap(\.input).first(where: {
                       !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                   }) {
                    keepTool.input = latestInput
                }
                if let finalStatus = orderedTodoTools.last?.status {
                    keepTool.status = finalStatus
                }
                keepTool.name = "TodoWrite"
                resolved[keepID] = keepTool
            }

            for id in todoIDs where id != keepID {
                suppressedToolIDs.insert(id)
            }
        }

        return OpenCodeToolLifecycleProjection(
            resolvedToolStateById: resolved,
            suppressedToolIDs: suppressedToolIDs
        )
    }

    private static func buildBackgroundLifecycleComponents(
        resolvedTools: [String: CLIMessage.ToolUse]
    ) -> [[String]] {
        var identifiersByToolID: [String: Set<String>] = [:]
        var toolIDsByIdentifier: [String: Set<String>] = [:]

        for (toolID, tool) in resolvedTools {
            let identifiers = backgroundTaskLifecycleIdentifiers(for: tool)
            guard shouldParticipateInBackgroundLifecycle(tool: tool, lifecycleIdentifiers: identifiers) else {
                continue
            }
            guard !identifiers.isEmpty else {
                continue
            }

            identifiersByToolID[toolID] = identifiers
            for identifier in identifiers {
                toolIDsByIdentifier[identifier, default: []].insert(toolID)
            }
        }

        var visited = Set<String>()
        var components: [[String]] = []

        for startToolID in identifiersByToolID.keys {
            if visited.contains(startToolID) {
                continue
            }

            var queue: [String] = [startToolID]
            var component = Set<String>()
            while let current = queue.popLast() {
                if !visited.insert(current).inserted {
                    continue
                }
                component.insert(current)

                let identifiers = identifiersByToolID[current] ?? []
                for identifier in identifiers {
                    for neighbor in toolIDsByIdentifier[identifier] ?? [] where !visited.contains(neighbor) {
                        queue.append(neighbor)
                    }
                }
            }

            if !component.isEmpty {
                components.append(component.sorted())
            }
        }

        return components
    }

    private static func preferredVisibleToolID(
        ids: [String],
        latestToolMessageIndexById: [String: Int],
        resolvedTools: [String: CLIMessage.ToolUse]
    ) -> String? {
        ids.max { lhs, rhs in
            let lhsIndex = latestToolMessageIndexById[lhs] ?? Int.min
            let rhsIndex = latestToolMessageIndexById[rhs] ?? Int.min
            if lhsIndex != rhsIndex {
                return lhsIndex < rhsIndex
            }

            let lhsRank = statusRank(resolvedTools[lhs]?.status)
            let rhsRank = statusRank(resolvedTools[rhs]?.status)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            return lhs < rhs
        }
    }

    private static func statusRank(_ status: CLIMessage.ToolUse.Status?) -> Int {
        switch status {
        case .error:
            return 4
        case .success:
            return 3
        case .running:
            return 2
        case .pending:
            return 1
        case nil:
            return 0
        }
    }

    private static func derivedLifecycleStatus(for tool: CLIMessage.ToolUse) -> CLIMessage.ToolUse.Status? {
        let semanticKind = CLIToolSemantics.classifyToolName(tool.name)
        switch semanticKind {
        case .todo:
            return deriveTodoStatus(tool: tool) ?? tool.status
        case .backgroundTask:
            return deriveBackgroundTaskStatus(tool: tool) ?? tool.status
        default:
            let lifecycleIDs = backgroundTaskLifecycleIdentifiers(for: tool)
            if shouldParticipateInBackgroundLifecycle(tool: tool, lifecycleIdentifiers: lifecycleIDs) {
                return deriveBackgroundTaskStatus(tool: tool) ?? tool.status
            }
            return nil
        }
    }

    private static func shouldParticipateInBackgroundLifecycle(
        tool: CLIMessage.ToolUse,
        lifecycleIdentifiers: Set<String>
    ) -> Bool {
        let semanticKind = CLIToolSemantics.classifyToolName(tool.name)
        if semanticKind == .backgroundTask {
            return true
        }

        if !lifecycleIdentifiers.isEmpty {
            return true
        }

        if semanticKind == .task {
            return hasRunInBackgroundFlag(in: tool.input)
                || hasRunInBackgroundFlag(in: tool.output)
        }
        return false
    }

    private static func deriveTodoStatus(tool: CLIMessage.ToolUse) -> CLIMessage.ToolUse.Status? {
        let outputItems = ToolUseTodoParser.parseItems(from: tool.output)
        let inputItems = ToolUseTodoParser.parseItems(from: tool.input)
        let items = !outputItems.isEmpty ? outputItems : inputItems
        guard !items.isEmpty else { return nil }

        let normalizedStatuses = items.map { ToolUseTodoParser.normalizedStatus($0.status) }
        if normalizedStatuses.allSatisfy({ $0 == "completed" }) {
            return .success
        }
        if normalizedStatuses.contains("in_progress") {
            return .running
        }
        if normalizedStatuses.contains("completed") {
            return .running
        }
        if normalizedStatuses.allSatisfy({ $0 == "pending" }) {
            return .pending
        }
        return nil
    }

    private static func deriveBackgroundTaskStatus(tool: CLIMessage.ToolUse) -> CLIMessage.ToolUse.Status? {
        if tool.status == .error {
            return .error
        }

        if let status = deriveBackgroundStatusFromRaw(tool.output) {
            return status
        }
        if let status = deriveBackgroundStatusFromRaw(tool.input) {
            return status
        }
        return nil
    }

    private static func deriveBackgroundStatusFromRaw(_ raw: String?) -> CLIMessage.ToolUse.Status? {
        let objects = parseStructuredPayloadObjects(from: raw)
        guard !objects.isEmpty else { return nil }

        var statusTokens: [String] = []
        for object in objects {
            collectStatusTokens(from: object, into: &statusTokens)
        }

        for token in statusTokens.reversed() {
            if let mapped = statusFromToken(token) {
                return mapped
            }
        }
        return nil
    }

    private static func statusFromToken(_ token: String) -> CLIMessage.ToolUse.Status? {
        let normalized = token
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        if normalized.isEmpty {
            return nil
        }
        if ["failed", "error"].contains(normalized) {
            return .error
        }
        if ["completed", "success", "done", "cancelled", "canceled"].contains(normalized) {
            return .success
        }
        if ["running", "in_progress", "active"].contains(normalized) {
            return .running
        }
        if ["pending", "queued"].contains(normalized) {
            return .pending
        }
        return nil
    }

    private static func backgroundTaskLifecycleIdentifiers(for tool: CLIMessage.ToolUse) -> Set<String> {
        var identifiers = Set<String>()
        for raw in [tool.input, tool.output] {
            identifiers.formUnion(extractLifecycleIdentifiersFromStructuredPayload(raw))
        }
        return identifiers
    }

    private static func extractLifecycleIdentifiersFromStructuredPayload(_ raw: String?) -> Set<String> {
        var identifiers = Set<String>()
        let objects = parseStructuredPayloadObjects(from: raw)
        for object in objects {
            collectLifecycleIdentifiers(from: object, into: &identifiers)
        }
        return identifiers
    }

    private static func collectLifecycleIdentifiers(
        from object: [String: Any],
        into identifiers: inout Set<String>
    ) {
        if let taskID = firstString(in: object, keys: ["task_id", "taskId"]),
           looksLikeBackgroundTaskIdentifier(taskID) {
            identifiers.insert("task:\(taskID)")
        }
        if let sessionID = firstString(in: object, keys: ["sessionId", "session_id"]) {
            identifiers.insert("session:\(sessionID)")
        }
    }

    private static func hasRunInBackgroundFlag(in raw: String?) -> Bool {
        let objects = parseStructuredPayloadObjects(from: raw)
        for object in objects {
            if boolValue(for: object["run_in_background"]) {
                return true
            }
            if let rawInput = object["rawInput"] as? [String: Any],
               boolValue(for: rawInput["run_in_background"]) {
                return true
            }
        }
        return false
    }

    private static func parseStructuredPayloadObjects(from raw: String?) -> [[String: Any]] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var values: [Any] = []
        if let parsed = ToolUseJSONParser.parseJSON(trimmed) {
            values.append(parsed)
        } else {
            for segment in trimmed.components(separatedBy: "\n\n") {
                let segmentTrimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !segmentTrimmed.isEmpty else { continue }
                if let parsed = ToolUseJSONParser.parseJSON(segmentTrimmed) {
                    values.append(parsed)
                }
            }
        }

        var objects: [[String: Any]] = []
        for value in values {
            collectJSONObjectCandidates(from: value, into: &objects)
        }
        return objects
    }

    private static func collectJSONObjectCandidates(
        from value: Any,
        into objects: inout [[String: Any]]
    ) {
        if let dict = value as? [String: Any] {
            objects.append(dict)
            if let rawInput = dict["rawInput"] as? [String: Any] {
                objects.append(rawInput)
            }
            if let rawOutput = dict["rawOutput"] as? [String: Any] {
                objects.append(rawOutput)
            }
            if let metadata = (dict["rawOutput"] as? [String: Any])?["metadata"] as? [String: Any] {
                objects.append(metadata)
            }
            if let metadata = dict["metadata"] as? [String: Any] {
                objects.append(metadata)
            }
            if let payload = dict["payload"] as? [String: Any] {
                objects.append(payload)
            }
            return
        }

        if let list = value as? [Any] {
            for item in list {
                collectJSONObjectCandidates(from: item, into: &objects)
            }
        }
    }

    private static func collectStatusTokens(from value: Any, into tokens: inout [String]) {
        if let dict = value as? [String: Any] {
            for (key, value) in dict {
                let normalizedKey = key
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if normalizedKey == "status" || normalizedKey == "state",
                   let token = value as? String {
                    tokens.append(token)
                }
                collectStatusTokens(from: value, into: &tokens)
            }
            return
        }

        if let list = value as? [Any] {
            for item in list {
                collectStatusTokens(from: item, into: &tokens)
            }
        }
    }

    private static func firstString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        for nestedKey in ["rawInput", "rawOutput", "payload", "metadata", "data"] {
            if let nested = dict[nestedKey] as? [String: Any],
               let value = firstString(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    private static func boolValue(for value: Any?) -> Bool {
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

    private static func looksLikeBackgroundTaskIdentifier(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return normalized.hasPrefix("bg_")
            || normalized.hasPrefix("bg-")
    }

    private static func mergeLifecycleText(_ texts: [String]) -> String? {
        let cleaned = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }

        var merged: [String] = []
        for text in cleaned {
            if merged.last == text {
                continue
            }
            if merged.contains(text) {
                continue
            }
            merged.append(text)
        }

        guard !merged.isEmpty else { return nil }
        return merged.joined(separator: "\n\n")
    }
}
