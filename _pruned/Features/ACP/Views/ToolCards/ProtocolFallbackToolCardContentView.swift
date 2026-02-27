//
//  ProtocolFallbackToolCardContentView.swift
//  contextgo
//
//  Protocol fallback tool card renderer.
//

import SwiftUI

struct ProtocolFallbackToolCardContentView: View {
    let context: ToolCardRenderContext
    @State private var showRawPayload = false

    private var parsedOutput: (eventName: String?, payload: String?) {
        Self.parseFallbackOutput(context.resolvedOutput)
    }

    private var protocolEventName: String? {
        if let parsed = parsedOutput.eventName, !parsed.isEmpty {
            return parsed
        }
        let rawName = context.toolUse.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawName.isEmpty else { return nil }
        if rawName.hasPrefix("protocol.") {
            return String(rawName.dropFirst("protocol.".count))
        }
        return rawName
    }

    private var outputPayload: String? {
        if let payload = parsedOutput.payload,
           !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return payload
        }
        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return output
        }
        return nil
    }

    private var inputPayload: String? {
        if let input = context.resolvedInput,
           !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return input
        }
        return nil
    }

    private var hasRawPayload: Bool {
        outputPayload != nil || inputPayload != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(context.toolUse.name)")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)

            if let eventName = protocolEventName,
               !eventName.isEmpty {
                Label(eventName, systemImage: "shippingbox")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            if let summary = context.resolvedOutput,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(ToolCardSemanticHelpers.firstMeaningfulLine(from: summary, maxLength: 180))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            if hasRawPayload {
                DisclosureGroup("原始 ACP payload（点击展开）", isExpanded: $showRawPayload) {
                    VStack(alignment: .leading, spacing: 12) {
                        if let outputPayload {
                            payloadSection(
                                title: "输出 payload",
                                icon: "arrow.up.circle",
                                raw: outputPayload,
                                isError: context.toolUse.status == .error
                            )
                        }

                        if let inputPayload {
                            payloadSection(
                                title: "输入 payload",
                                icon: "arrow.down.circle",
                                raw: inputPayload,
                                isError: false
                            )
                        }
                    }
                }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func payloadSection(title: String, icon: String, raw: String, isError: Bool) -> some View {
        DetailSection(title: title, icon: icon, copyText: raw) {
            if isError {
                ErrorBlock(text: raw)
            } else if let parsed = ToolUseJSONParser.parseJSON(raw) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Self.payloadStructureSummary(parsed))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    CodeBlock(text: ToolUseJSONParser.prettyPrintedJSONIfPossible(raw))
                }
            } else {
                CodeBlock(text: raw)
            }
        }
    }
}

extension ProtocolFallbackToolCardContentView {
    static func summaryText(for context: ToolCardRenderContext) -> String {
        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let parsed = parseFallbackOutput(output)
            if let eventName = parsed.eventName, !eventName.isEmpty {
                return "未映射协议事件: \(eventName)"
            }
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: output)
        }

        if let input = context.resolvedInput,
           !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: input)
        }

        return context.toolUse.name
    }

    fileprivate static func parseFallbackOutput(_ raw: String?) -> (eventName: String?, payload: String?) {
        guard let raw else { return (nil, nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return (nil, nil) }

        let marker = "[未适配协议事件]"
        guard trimmed.hasPrefix(marker) else {
            return (nil, trimmed)
        }

        let lineParts = trimmed.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let firstLine = String(lineParts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
        let eventName = firstLine
            .replacingOccurrences(of: marker, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let payload = lineParts.count > 1
            ? String(lineParts[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        return (eventName.isEmpty ? nil : eventName, payload?.isEmpty == true ? nil : payload)
    }

    fileprivate static func payloadStructureSummary(_ value: Any) -> String {
        if let dict = value as? [String: Any] {
            let keys = dict.keys.sorted()
            let preview = keys.prefix(6).joined(separator: ", ")
            if keys.count > 6 {
                return "对象 · \(keys.count) 个字段（\(preview), ...）"
            }
            return "对象 · \(keys.count) 个字段（\(preview)）"
        }

        if let array = value as? [Any] {
            return "数组 · \(array.count) 项"
        }

        return "标量值"
    }
}
