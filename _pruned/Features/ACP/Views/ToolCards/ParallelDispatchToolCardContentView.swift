//
//  ParallelDispatchToolCardContentView.swift
//  contextgo
//
//  Parallel dispatch tool card renderer.
//

import SwiftUI

struct ParallelDispatchToolCardContentView: View {
    let context: ToolCardRenderContext

    private var operations: [ParallelDispatchOperationSnapshot] {
        let merged = ToolCardSemanticHelpers.parseParallelDispatchOperations(context.resolvedInput)
            + ToolCardSemanticHelpers.parseParallelDispatchOperations(context.resolvedOutput)

        var seen = Set<String>()
        var unique: [ParallelDispatchOperationSnapshot] = []
        for operation in merged {
            let key = "\(operation.title)|\(operation.detail ?? "")|\(operation.icon)"
            if seen.insert(key).inserted {
                unique.append(operation)
            }
        }
        return unique
    }

    var body: some View {
        DetailSection(title: title, icon: "square.stack.3d.up") {
            if operations.isEmpty {
                Text(ParallelDispatchToolCardContentView.summaryText(for: context))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(operations) { operation in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: operation.icon)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 14)

                            Text(singleLineText(for: operation))
                                .font(.system(size: 12))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var title: String {
        context.normalizedProviderFlavor == "codex" ? "Explored" : "并行步骤"
    }

    private func singleLineText(for operation: ParallelDispatchOperationSnapshot) -> String {
        if let detail = operation.detail,
           !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(operation.title): \(detail)"
        }
        return operation.title
    }
}

extension ParallelDispatchToolCardContentView {
    static func summaryText(for context: ToolCardRenderContext) -> String {
        let operations = ToolCardSemanticHelpers.parseParallelDispatchOperations(context.resolvedInput)
            + ToolCardSemanticHelpers.parseParallelDispatchOperations(context.resolvedOutput)

        if let first = operations.first {
            let firstLabel = first.detail ?? first.title
            if operations.count == 1 {
                return firstLabel
            }
            return "\(firstLabel) 等 \(operations.count) 项"
        }

        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: output)
        }

        return context.normalizedProviderFlavor == "codex" ? "Explored" : "并行工具调度"
    }
}
