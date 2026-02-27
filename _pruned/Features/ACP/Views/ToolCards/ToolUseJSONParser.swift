//
//  ToolUseJSONParser.swift
//  contextgo
//
//  Shared JSON parsing/pretty-print helpers for tool cards.
//

import Foundation

private final class ToolUseJSONCacheEntry: NSObject {
    let value: Any?

    init(value: Any?) {
        self.value = value
    }
}

enum ToolUseJSONParser {
    private static let parsedJSON: NSCache<NSString, ToolUseJSONCacheEntry> = {
        let cache = NSCache<NSString, ToolUseJSONCacheEntry>()
        cache.countLimit = 1024
        return cache
    }()

    private static let prettyJSON: NSCache<NSString, NSString> = {
        let cache = NSCache<NSString, NSString>()
        cache.countLimit = 1024
        return cache
    }()

    static func parseJSON(_ raw: String) -> Any? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > 1_500_000 {
            return nil
        }

        let key = trimmed as NSString
        if let cached = parsedJSON.object(forKey: key) {
            return cached.value
        }

        var parsed: Any?
        let candidates = jsonCandidates(from: trimmed)
        for candidate in candidates {
            guard let data = candidate.data(using: .utf8) else { continue }
            parsed = try? JSONSerialization.jsonObject(with: data, options: [])
            if parsed != nil {
                break
            }
        }

        parsedJSON.setObject(ToolUseJSONCacheEntry(value: parsed), forKey: key)
        return parsed
    }

    static func prettyPrintedJSONIfPossible(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return raw }

        let key = trimmed as NSString
        if let cached = prettyJSON.object(forKey: key) {
            return cached as String
        }

        guard let json = parseJSON(trimmed),
              JSONSerialization.isValidJSONObject(json),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]),
              let text = String(data: data, encoding: .utf8) else {
            return raw
        }
        prettyJSON.setObject(text as NSString, forKey: key)
        return text
    }

    private static func jsonCandidates(from raw: String) -> [String] {
        var candidates: [String] = []

        func appendCandidate(_ candidate: String?) {
            guard let candidate else { return }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return }
            if !candidates.contains(trimmed) {
                candidates.append(trimmed)
            }
        }

        appendCandidate(raw)
        appendCandidate(balancedJSONPrefix(from: raw))

        if raw.hasPrefix("```"),
           let fenceStart = raw.firstIndex(of: "\n"),
           let fenceEnd = raw.range(of: "```", options: .backwards),
           fenceStart < fenceEnd.lowerBound {
            let inner = raw[raw.index(after: fenceStart)..<fenceEnd.lowerBound]
            appendCandidate(String(inner))
        }

        if let newlineIndex = raw.firstIndex(of: "\n") {
            let suffix = raw[raw.index(after: newlineIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            appendCandidate(suffix)
            appendCandidate(balancedJSONPrefix(from: suffix))
        }

        if raw.hasPrefix("\"") || raw.hasPrefix("'") {
            if let data = raw.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(String.self, from: data) {
                appendCandidate(decoded)
            }
        }

        return candidates
    }

    // Extract a valid JSON prefix when payload has non-JSON trailing annotations
    // (e.g. "... [payload trimmed ...]").
    private static func balancedJSONPrefix(from raw: String) -> String? {
        guard let start = raw.firstIndex(where: { $0 == "{" || $0 == "[" }) else {
            return nil
        }

        var stack: [Character] = []
        var inString = false
        var isEscaped = false
        var cursor = start

        while cursor < raw.endIndex {
            let ch = raw[cursor]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
                cursor = raw.index(after: cursor)
                continue
            }

            if ch == "\"" {
                inString = true
                cursor = raw.index(after: cursor)
                continue
            }

            if ch == "{" || ch == "[" {
                stack.append(ch)
                cursor = raw.index(after: cursor)
                continue
            }

            if ch == "}" || ch == "]" {
                guard let last = stack.last else { return nil }
                let matched = (last == "{" && ch == "}") || (last == "[" && ch == "]")
                guard matched else { return nil }

                stack.removeLast()
                if stack.isEmpty {
                    return String(raw[start...cursor])
                }
                cursor = raw.index(after: cursor)
                continue
            }

            cursor = raw.index(after: cursor)
        }

        return nil
    }
}
