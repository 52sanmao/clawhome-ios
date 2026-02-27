//
//  ToolUseTodoParser.swift
//  contextgo
//
//  Todo payload parser used by tool card rendering.
//

import Foundation

enum ToolUseTodoParser {
    static func parseItems(from raw: String?) -> [TodoItemSnapshot] {
        guard let raw else { return [] }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        guard let json = ToolUseJSONParser.parseJSON(trimmed),
              let rawTodos = extractTodoArray(from: json) else {
            return []
        }

        let parsed = rawTodos.enumerated().compactMap { index, value in
            parseTodoItem(from: value, index: index)
        }

        return parsed.sorted { lhs, rhs in
            let lhsOrder = statusOrder(normalizedStatus(lhs.status))
            let rhsOrder = statusOrder(normalizedStatus(rhs.status))
            if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
            return lhs.content < rhs.content
        }
    }

    static func normalizedStatus(_ raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "in_progress", "in-progress", "running", "active":
            return "in_progress"
        case "done", "completed", "complete", "success":
            return "completed"
        case "pending", "todo", "queued", "open":
            return "pending"
        default:
            return key.isEmpty ? "pending" : key
        }
    }

    static func statusOrder(_ status: String) -> Int {
        switch status {
        case "in_progress":
            return 0
        case "pending":
            return 1
        case "completed":
            return 2
        default:
            return 3
        }
    }

    private static func extractTodoArray(from value: Any) -> [Any]? {
        func looksLikeTodoArray(_ raw: [Any]) -> Bool {
            raw.contains { item in
                guard let dict = item as? [String: Any] else { return false }
                return dict["content"] != nil
                    || dict["title"] != nil
                    || dict["text"] != nil
                    || dict["task"] != nil
                    || dict["status"] != nil
                    || dict["priority"] != nil
            }
        }

        if let array = value as? [Any], looksLikeTodoArray(array) {
            return array
        }

        var queue: [Any] = [value]
        var cursor = 0
        var scannedNodes = 0
        let maxNodes = 1024

        while cursor < queue.count && scannedNodes < maxNodes {
            let current = queue[cursor]
            cursor += 1
            scannedNodes += 1

            if let array = current as? [Any], looksLikeTodoArray(array) {
                return array
            }

            if let array = current as? [Any] {
                for item in array {
                    queue.append(item)
                }
                continue
            }

            guard let dict = current as? [String: Any] else { continue }

            if let todos = dict["todos"] as? [Any], !todos.isEmpty {
                return todos
            }
            if let items = dict["items"] as? [Any], !items.isEmpty {
                return items
            }
            if let data = dict["data"] as? [Any], !data.isEmpty, looksLikeTodoArray(data) {
                return data
            }

            if let output = dict["output"] {
                queue.append(output)
            }
            if let content = dict["content"] {
                queue.append(content)
            }
            if let data = dict["data"] {
                queue.append(data)
            }
            if let payload = dict["payload"] {
                queue.append(payload)
            }
            if let result = dict["result"] {
                queue.append(result)
            }
            if let entries = dict["entries"] {
                queue.append(entries)
            }
        }

        return nil
    }

    private static func parseTodoItem(from value: Any, index: Int) -> TodoItemSnapshot? {
        guard let dict = value as? [String: Any] else { return nil }

        let content = valueAsString(dict["content"])
            ?? valueAsString(dict["title"])
            ?? valueAsString(dict["text"])
            ?? valueAsString(dict["task"])
        guard let content, !content.isEmpty else { return nil }

        let status = normalizedStatus(valueAsString(dict["status"]) ?? "pending")
        let priority = valueAsString(dict["priority"])
        let id = valueAsString(dict["id"]) ?? "todo-\(index)-\(status)"
        return TodoItemSnapshot(id: id, content: content, status: status, priority: priority)
    }

    private static func valueAsString(_ value: Any?) -> String? {
        guard let value else { return nil }
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let array = value as? [Any] {
            let joined = array.map { String(describing: $0) }.joined(separator: " ")
            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return String(describing: value)
    }
}
