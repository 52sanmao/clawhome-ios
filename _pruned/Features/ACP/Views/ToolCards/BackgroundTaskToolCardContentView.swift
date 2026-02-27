//
//  BackgroundTaskToolCardContentView.swift
//  contextgo
//
//  Background task tool card renderer.
//

import SwiftUI

struct BackgroundTaskToolCardContentView: View {
    let context: ToolCardRenderContext

    private var parsedInput: ParsedBackgroundTaskInput? {
        ToolCardSemanticHelpers.parseBackgroundTaskInput(context.resolvedInput)
    }

    private var todoItems: [TodoItemSnapshot] {
        ToolUseTodoParser.parseItems(from: context.resolvedOutput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let parsedInput {
                HStack(spacing: 8) {
                    if let state = ToolCardSemanticHelpers.backgroundTaskStateLabel(from: parsedInput.state), !state.isEmpty {
                        Label(state, systemImage: "tray.2")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if let taskId = parsedInput.taskId, !taskId.isEmpty {
                        Text(taskId)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                if let title = parsedInput.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                }

                if let detail = parsedInput.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(3)
                }
            }

            if let summary = ToolCardSemanticHelpers.todoProgressSummary(from: todoItems) {
                Text(summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
            }

            if let executionSummary = context.taskExecutionSummary,
               !executionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DetailSection(title: "执行进度", icon: "list.bullet.rectangle") {
                    Text(executionSummary)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let output = context.resolvedOutput,
               !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               todoItems.isEmpty {
                DetailSection(title: "输出", icon: "arrow.up.circle") {
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
        }
    }
}

extension BackgroundTaskToolCardContentView {
    static func summaryText(for context: ToolCardRenderContext) -> String {
        let todoItems = ToolUseTodoParser.parseItems(from: context.resolvedOutput)
        if let summary = ToolCardSemanticHelpers.todoProgressSummary(from: todoItems) {
            return summary
        }

        if let taskExecutionSummary = context.taskExecutionSummary,
           !taskExecutionSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: taskExecutionSummary)
        }

        if let parsed = ToolCardSemanticHelpers.parseBackgroundTaskInput(context.resolvedInput) {
            if let detail = parsed.detail, !detail.isEmpty {
                return ToolCardSemanticHelpers.firstMeaningfulLine(from: detail)
            }
            if let title = parsed.title, !title.isEmpty {
                return ToolCardSemanticHelpers.firstMeaningfulLine(from: title)
            }
            if let state = ToolCardSemanticHelpers.backgroundTaskStateLabel(from: parsed.state), !state.isEmpty {
                return "后台任务\(state)"
            }
        }

        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: output)
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
