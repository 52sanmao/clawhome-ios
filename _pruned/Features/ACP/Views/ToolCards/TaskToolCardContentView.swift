//
//  TaskToolCardContentView.swift
//  contextgo
//
//  Sub-agent task tool card renderers.
//

import SwiftUI

struct TaskToolCardContentView: View {
    let context: ToolCardRenderContext
    let onOpenDetail: () -> Void

    private var parsedInput: ParsedTaskInput? {
        ToolCardSemanticHelpers.parseTaskInput(context.resolvedInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let parsedInput {
                HStack(spacing: 8) {
                    Label(parsedInput.subagentType, systemImage: "cpu")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }

                if let description = parsedInput.description,
                   !description.isEmpty {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
            }

            if let output = context.resolvedOutput,
               !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DetailSection(title: "结果", icon: "checkmark.seal") {
                    if context.toolUse.status == .error {
                        ErrorBlock(text: output)
                    } else {
                        Text(ToolCardSemanticHelpers.firstMeaningfulLine(from: output, maxLength: 180))
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let summary = context.taskExecutionSummary,
               !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DetailSection(title: "执行进度", icon: "list.bullet.rectangle") {
                    Text(summary)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Button(action: onOpenDetail) {
                Label("查看任务详情", systemImage: "arrow.up.right.square")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
        }
    }
}

struct TaskToolCardDetailSheetView: View {
    let context: ToolCardRenderContext
    let loadState: ToolCardDetailLoadState
    let onClose: () -> Void

    private var parsedInput: ParsedTaskInput? {
        ToolCardSemanticHelpers.parseTaskInput(context.resolvedInput)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if loadState.isLoading {
                        ProgressView("加载中...")
                    }

                    if let error = loadState.errorMessage,
                       !error.isEmpty {
                        ErrorBlock(text: error)
                    }

                    if let parsedInput {
                        DetailSection(title: "子代理", icon: "cpu") {
                            Text(parsedInput.subagentType)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.primary)
                        }

                        if let description = parsedInput.description,
                           !description.isEmpty {
                            DetailSection(title: "说明", icon: "text.quote", copyText: description) {
                                Text(description)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }

                        if let prompt = parsedInput.prompt,
                           !prompt.isEmpty {
                            DetailSection(title: "Prompt", icon: "arrow.down.circle", copyText: prompt) {
                                CodeBlock(text: prompt)
                            }
                        }
                    }

                    if let summary = context.taskExecutionSummary,
                       !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSection(title: "执行摘要", icon: "list.bullet.rectangle", copyText: summary) {
                            Text(summary)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let output = context.resolvedOutput,
                       !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSection(title: "输出", icon: "arrow.up.circle", copyText: output) {
                            if context.toolUse.status == .error {
                                ErrorBlock(text: output)
                            } else {
                                CodeBlock(text: ToolCardSemanticHelpers.readableToolOutput(output))
                            }
                        }
                    }

                    if let input = context.resolvedInput,
                       !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSection(title: "输入 payload", icon: "tray.full", copyText: input) {
                            CodeBlock(text: ToolCardSemanticHelpers.prettyPrintedJSONIfPossible(input))
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("任务详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", action: onClose)
                }
            }
        }
    }
}

extension TaskToolCardContentView {
    static func summaryText(for context: ToolCardRenderContext) -> String {
        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: output)
        }

        if let parsed = ToolCardSemanticHelpers.parseTaskInput(context.resolvedInput),
           let description = parsed.description,
           !description.isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: description)
        }

        if let taskExecutionSummary = context.taskExecutionSummary,
           !taskExecutionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: taskExecutionSummary)
        }

        return "子代理任务"
    }
}
