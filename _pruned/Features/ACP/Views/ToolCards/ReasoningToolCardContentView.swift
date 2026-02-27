//
//  ReasoningToolCardContentView.swift
//  contextgo
//
//  Inline reasoning card renderer.
//

import SwiftUI

struct ReasoningToolCardContentView: View {
    let context: ToolCardRenderContext

    private var reasoningText: String {
        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return output
        }
        if let input = context.resolvedInput,
           !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return input
        }
        return "暂无思考内容"
    }

    var body: some View {
        DisclosureGroup {
            Text(reasoningText)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)

                    Text("思考过程")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.secondary)

                    Spacer()

                    CopyTextButton(text: reasoningText)
                    StatusBadge(status: context.toolUse.status)
                }

                Text(ToolCardSemanticHelpers.firstMeaningfulLine(from: reasoningText, maxLength: 160))
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.systemGray6))
        )
    }
}

extension ReasoningToolCardContentView {
    static func summaryText(for context: ToolCardRenderContext) -> String {
        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: output)
        }
        if let input = context.resolvedInput,
           !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: input)
        }
        return "思考中..."
    }
}
