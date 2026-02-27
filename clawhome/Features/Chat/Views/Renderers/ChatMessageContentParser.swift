//
//  ChatMessageContentParser.swift
//  contextgo
//
//  Text segment parser for chat rendering (legacy CTXGO marker protocol removed).
//

import Foundation

enum ChatMessageContentParser {
    static func extractThinkingContent(from text: String) -> String? {
        guard let start = text.range(of: "<thinking>"),
              let end = text.range(of: "</thinking>") else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removeThinkingContent(from text: String) -> String? {
        guard let start = text.range(of: "<thinking>"),
              let end = text.range(of: "</thinking>") else {
            return text
        }
        var stripped = text
        stripped.removeSubrange(start.lowerBound..<end.upperBound)
        return stripped
    }

    static func parseSegments(from text: String, isUserMessage _: Bool) -> [ChatMessageSegment] {
        splitMarkdownAndMediaSegments(from: text)
    }

    private static func splitMarkdownAndMediaSegments(from markdown: String) -> [ChatMessageSegment] {
        var segments: [ChatMessageSegment] = []
        var markdownBuffer: [String] = []
        var hasMediaToken = false

        for line in markdown.components(separatedBy: "\n") {
            if let mediaURL = parseMediaURL(from: line) {
                hasMediaToken = true
                if !markdownBuffer.isEmpty {
                    let bufferedText = markdownBuffer.joined(separator: "\n")
                    if !bufferedText.isEmpty {
                        segments.append(.markdown(bufferedText))
                    }
                    markdownBuffer.removeAll()
                }
                segments.append(.media(mediaURL))
            } else {
                markdownBuffer.append(line)
            }
        }

        if !markdownBuffer.isEmpty {
            let bufferedText = markdownBuffer.joined(separator: "\n")
            if !bufferedText.isEmpty {
                segments.append(.markdown(bufferedText))
            }
        }

        if !hasMediaToken {
            return [.markdown(markdown)]
        }
        return segments
    }

    private static func parseMediaURL(from line: String) -> URL? {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedLine.hasPrefix("MEDIA:") else {
            return nil
        }

        let rawURL = String(trimmedLine.dropFirst("MEDIA:".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty,
              let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }

        return url
    }
}
