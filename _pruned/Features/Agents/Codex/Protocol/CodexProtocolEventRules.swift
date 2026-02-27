import Foundation

enum CodexProtocolEventRules {
    private static let silentProtocolEventTypes: Set<String> = [
        "status",
        "event.status",
        "event.codex.event.status",
        "item.started",
        "item.completed",
        "item_started",
        "item_completed",
        "event.item.started",
        "event.item.completed",
        "runtime_metadata",
        "runtime-metadata",
        "runtime.metadata",
        "event.runtime.metadata",
        "event_runtime_metadata",
        "event.thread.started",
        "event.thread.archived",
        "event.thread.unarchived",
        "event.account.updated",
        "event.account.ratelimits.updated",
        "event.item.reasoning.summarypartadded",
        "event.codex.event.mcp.startup.complete",
        "event.codex.event.mcp.startup.update",
        "event.thread.tokenusage.updated",
        "agent.reasoning.section.break",
        "agent_reasoning_section_break"
    ]

    private static let silentProtocolEventNames: Set<String> = [
        "status",
        "codex.event.status",
        "item.started",
        "item.completed",
        "item_started",
        "item_completed",
        "codex.event.item.started",
        "codex.event.item.completed",
        "runtime-metadata",
        "thread.started",
        "thread.archived",
        "thread.unarchived",
        "account.updated",
        "account.ratelimits.updated",
        "item.reasoning.summarypartadded",
        "codex.event.mcp.startup.complete",
        "codex.event.mcp.startup.update",
        "thread.tokenusage.updated",
        "agent.reasoning.section.break",
        "agent_reasoning_section_break"
    ]

    static func isSilentProtocolEvent(rawType: String, contentData: [String: Any]) -> Bool {
        let normalizedType = rawType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let canonicalType = canonicalProtocolEventMarker(normalizedType)
        if silentProtocolEventTypes.contains(normalizedType)
            || silentProtocolEventTypes.contains(canonicalType) {
            return true
        }

        guard normalizedType == "event" else {
            return false
        }

        guard let eventName = (contentData["name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return false
        }

        let canonicalEventName = canonicalProtocolEventMarker(eventName)
        return silentProtocolEventNames.contains(eventName)
            || silentProtocolEventNames.contains(canonicalEventName)
    }

    static func isSilentProtocolEventText(_ text: String) -> Bool {
        let lowered = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("reasoning section break")
            || lowered.hasPrefix("reasoning section #") {
            return true
        }

        let canonical = canonicalProtocolEventMarker(text)
        guard !canonical.isEmpty else { return false }

        let codexNormalized: String = {
            let prefixes = [
                "event.codex.event.",
                "codex.event.",
                "event.codex.",
                "codex."
            ]
            for prefix in prefixes where canonical.hasPrefix(prefix) {
                return String(canonical.dropFirst(prefix.count))
            }
            return canonical
        }()

        let eventNormalized = canonical.hasPrefix("event.")
            ? String(canonical.dropFirst("event.".count))
            : canonical

        let silentNames: Set<String> = [
            "status",
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

    static func isStatusOnlyProtocolFallbackText(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lowered = trimmed.lowercased()

        if lowered == "[未适配协议事件] status"
            || lowered.hasPrefix("[未适配协议事件] status\n")
            || lowered == "[unsupported protocol event] status"
            || lowered.hasPrefix("[unsupported protocol event] status\n") {
            return true
        }

        let canonical = canonicalProtocolEventMarker(trimmed)
        if canonical == "status"
            || canonical == "event.status"
            || canonical == "codex.event.status" {
            return true
        }

        return false
    }

    static func isSilentStatusTool(name: String, output: String?) -> Bool {
        let canonicalName = canonicalProtocolEventMarker(name)
        if canonicalName == "status"
            || canonicalName == "event.status"
            || canonicalName == "codex.event.status"
            || canonicalName == "protocol.status"
            || canonicalName == "protocol.event.status"
            || canonicalName == "protocol.codex.event.status" {
            return true
        }

        if let output, isStatusOnlyProtocolFallbackText(output) {
            return true
        }

        return false
    }

    static func canonicalProtocolEventMarker(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return "" }

        let dotted = trimmed
            .replacingOccurrences(of: "/", with: ".")
            .replacingOccurrences(of: "_", with: ".")
            .replacingOccurrences(of: "-", with: ".")

        let collapsed = dotted.replacingOccurrences(
            of: #"\.+"#,
            with: ".",
            options: .regularExpression
        )

        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
