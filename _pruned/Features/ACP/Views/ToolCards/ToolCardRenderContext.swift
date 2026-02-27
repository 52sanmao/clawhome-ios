//
//  ToolCardRenderContext.swift
//  contextgo
//
//  Shared render context and routing metadata for CLI tool cards.
//

import Foundation

enum ToolCardDetailSheet: String, Identifiable {
    case task
    case command
    case generic
    case todo

    var id: String { rawValue }
}

enum ToolCardSummaryStyle {
    case body
    case monospaced
}

enum ToolCardTapBehavior {
    case openSheet(ToolCardDetailSheet)
}

enum ToolCardLayout {
    case standard
}

struct ToolCardDetailLoadState {
    let isLoading: Bool
    let errorMessage: String?
}

struct ToolCardDescriptor {
    let layout: ToolCardLayout
    let displayName: String
    let iconName: String
    let summaryText: String
    let summaryStyle: ToolCardSummaryStyle
    let tapBehavior: ToolCardTapBehavior
}

struct ToolCardRenderContext {
    let toolUse: CLIMessage.ToolUse
    let providerFlavor: String?
    let semanticKind: CLIToolCardKind
    let taskExecutionSummary: String?
    let resolvedInput: String?
    let resolvedOutput: String?
    let hasSidecarPayloadRef: Bool

    var normalizedProviderFlavor: String {
        (providerFlavor ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    var payloadCharacterCount: Int {
        (resolvedInput?.count ?? 0) + (resolvedOutput?.count ?? 0)
    }

    var payloadLineCount: Int {
        let inputLines = resolvedInput?.utf8.reduce(into: 1) { count, value in
            if value == 10 { count += 1 }
        } ?? 0
        let outputLines = resolvedOutput?.utf8.reduce(into: 1) { count, value in
            if value == 10 { count += 1 }
        } ?? 0
        return inputLines + outputLines
    }
}
