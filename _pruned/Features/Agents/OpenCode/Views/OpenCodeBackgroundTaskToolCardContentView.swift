import Foundation
import SwiftUI

struct OpenCodeBackgroundTaskToolCardContentView: View {
    let context: ToolCardRenderContext

    private var snapshot: OpenCodeBackgroundTaskSnapshot {
        OpenCodeBackgroundTaskSnapshot.build(from: context)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description = snapshot.description {
                Text(description)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(3)
            }

            HStack(spacing: 8) {
                if let statusText = snapshot.localizedStateLabel {
                    Label(statusText, systemImage: snapshot.stateIconName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if let taskId = snapshot.taskId {
                    Text(taskId)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if let sessionId = snapshot.sessionId {
                Text("Session: \(sessionId)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let prompt = snapshot.prompt {
                DetailSection(title: "任务 Prompt", icon: "text.quote") {
                    Text(prompt)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let outputSummary = snapshot.outputSummary {
                DetailSection(title: "输出摘要", icon: "doc.text.magnifyingglass") {
                    Text(outputSummary)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let metrics = snapshot.metricsSummary {
                Text(metrics)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if snapshot.payloadTrimmed {
                Text("输出较长，已截断展示。可点右上角 info 查看 Raw。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

extension OpenCodeBackgroundTaskToolCardContentView {
    static func summaryText(for context: ToolCardRenderContext) -> String {
        let snapshot = OpenCodeBackgroundTaskSnapshot.build(from: context)

        if let description = snapshot.description {
            if let state = snapshot.localizedStateLabel {
                return "\(description) · \(state)"
            }
            return description
        }

        if let summary = snapshot.outputSummary {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: summary, maxLength: 180)
        }

        if let state = snapshot.localizedStateLabel {
            return "后台任务\(state)"
        }

        switch context.toolUse.status {
        case .running:
            return "后台任务执行中"
        case .success:
            return "后台任务已完成"
        case .error:
            return "后台任务失败"
        case .pending:
            return "后台任务等待中"
        }
    }
}

private struct OpenCodeBackgroundTaskSnapshot {
    var taskId: String?
    var sessionId: String?
    var description: String?
    var prompt: String?
    var stateRaw: String?
    var outputSummary: String?
    var totalMessages: Int?
    var returnedMessages: Int?
    var payloadTrimmed: Bool = false

    var localizedStateLabel: String? {
        guard let normalized = normalizedState else { return nil }
        switch normalized {
        case "running", "in_progress", "active":
            return "进行中"
        case "pending", "queued":
            return "排队中"
        case "failed", "error":
            return "失败"
        case "cancelled", "canceled":
            return "已关闭"
        case "completed", "success", "done":
            return "已完成"
        default:
            return normalized
        }
    }

    var stateIconName: String {
        guard let normalized = normalizedState else { return "checkmark.circle" }
        switch normalized {
        case "running", "in_progress", "active":
            return "clock.arrow.circlepath"
        case "pending", "queued":
            return "hourglass"
        case "failed", "error":
            return "xmark.octagon"
        case "cancelled", "canceled":
            return "checkmark.circle"
        case "completed", "success", "done":
            return "checkmark.circle"
        default:
            return "tray.2"
        }
    }

    var metricsSummary: String? {
        guard let totalMessages else { return nil }
        if let returnedMessages {
            return "背景会话消息: \(returnedMessages)/\(totalMessages)"
        }
        return "背景会话消息: \(totalMessages)"
    }

    private var normalizedState: String? {
        guard let stateRaw else { return nil }
        let normalized = stateRaw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
        return normalized.isEmpty ? nil : normalized
    }

    static func build(from context: ToolCardRenderContext) -> OpenCodeBackgroundTaskSnapshot {
        var snapshot = OpenCodeBackgroundTaskSnapshot()
        let input = context.resolvedInput ?? ""
        let output = context.resolvedOutput ?? ""

        let inputObjects = parseJSONObjects(from: input)
        let outputObjects = parseJSONObjects(from: output)
        let allObjects = inputObjects + outputObjects

        snapshot.taskId = firstString(in: allObjects, keys: ["task_id", "taskId"])
        snapshot.sessionId = firstString(in: allObjects, keys: ["sessionId", "session_id"])
        snapshot.description = firstString(in: inputObjects, keys: ["description"])
            ?? firstString(in: allObjects, keys: ["description", "title", "name"])
        snapshot.prompt = firstString(in: inputObjects, keys: ["prompt"])
            ?? firstString(in: allObjects, keys: ["prompt"])
        snapshot.stateRaw = lastStatus(in: outputObjects)
            ?? lastStatus(in: inputObjects)

        snapshot.totalMessages = lastInt(in: allObjects, keys: ["total_messages", "totalMessages"])
        snapshot.returnedMessages = lastInt(in: allObjects, keys: ["returned"])
        snapshot.payloadTrimmed = context.hasSidecarPayloadRef
            || containsBoolean(in: outputObjects, key: "truncated", value: true)

        snapshot.outputSummary = summarizedOutput(
            outputObjects: outputObjects,
            rawOutput: output,
            payloadTrimmed: snapshot.payloadTrimmed
        )

        return snapshot
    }

    private static func parseJSONObjects(from raw: String) -> [[String: Any]] {
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
                if let metadata = rawOutput["metadata"] as? [String: Any] {
                    objects.append(metadata)
                }
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

    private static func firstString(in objects: [[String: Any]], keys: [String]) -> String? {
        for object in objects {
            if let value = firstString(in: object, keys: keys) {
                return value
            }
        }
        return nil
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

        for nestedKey in ["rawInput", "rawOutput", "payload", "input", "output", "metadata", "data"] {
            if let nested = dict[nestedKey] as? [String: Any],
               let value = firstString(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    private static func lastInt(in objects: [[String: Any]], keys: [String]) -> Int? {
        for object in objects.reversed() {
            if let value = firstInt(in: object, keys: keys) {
                return value
            }
        }
        return nil
    }

    private static func firstInt(in dict: [String: Any], keys: [String]) -> Int? {
        for key in keys {
            if let value = dict[key] as? Int {
                return value
            }
            if let value = dict[key] as? String,
               let parsed = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return parsed
            }
        }

        for nestedKey in ["rawInput", "rawOutput", "payload", "input", "output", "metadata", "data"] {
            if let nested = dict[nestedKey] as? [String: Any],
               let value = firstInt(in: nested, keys: keys) {
                return value
            }
        }
        return nil
    }

    private static func lastStatus(in objects: [[String: Any]]) -> String? {
        for object in objects.reversed() {
            if let status = firstString(in: object, keys: ["status", "state"]) {
                return status
            }
        }
        return nil
    }

    private static func containsBoolean(
        in objects: [[String: Any]],
        key: String,
        value: Bool
    ) -> Bool {
        for object in objects {
            if boolValue(for: object[key]) == value {
                return true
            }
            for nestedKey in ["rawInput", "rawOutput", "payload", "input", "output", "metadata", "data"] {
                if let nested = object[nestedKey] as? [String: Any],
                   boolValue(for: nested[key]) == value {
                    return true
                }
            }
        }
        return false
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

    private static func summarizedOutput(
        outputObjects: [[String: Any]],
        rawOutput: String,
        payloadTrimmed: Bool
    ) -> String? {
        if containsBoolean(in: outputObjects, key: "truncated", value: true) || payloadTrimmed {
            return "Background output is large and trimmed."
        }

        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let preview = ToolCardSemanticHelpers.firstMeaningfulLine(from: trimmed, maxLength: 220)
        if preview.hasPrefix("{") || preview.hasPrefix("[") {
            return nil
        }
        return preview
    }
}
