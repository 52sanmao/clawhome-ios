//
//  TodoToolCardContentView.swift
//  contextgo
//
//  Todo / plan tool card renderers.
//

import SwiftUI

struct TodoToolCardContentView: View {
    let context: ToolCardRenderContext
    var onOpenDetail: (() -> Void)? = nil

    private var todoItems: [TodoItemSnapshot] {
        let fromOutput = ToolUseTodoParser.parseItems(from: context.resolvedOutput)
        if !fromOutput.isEmpty {
            return fromOutput
        }
        return ToolUseTodoParser.parseItems(from: context.resolvedInput)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = ToolCardSemanticHelpers.todoProgressSummary(from: todoItems) {
                Text(summary)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
            }

            if todoItems.isEmpty {
                Text("暂无 Todo 项")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(todoItems.prefix(4))) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(for: item.status))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(color(for: item.status))
                                .frame(width: 14)

                            Text(item.content)
                                .font(.system(size: 13))
                                .foregroundColor(.primary)
                                .lineLimit(2)
                        }
                    }
                }
            }

            if let onOpenDetail {
                Button(action: onOpenDetail) {
                    Label("查看完整计划", systemImage: "list.bullet.rectangle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func icon(for status: String) -> String {
        switch ToolUseTodoParser.normalizedStatus(status) {
        case "in_progress": return "arrow.triangle.2.circlepath"
        case "completed": return "checkmark.circle.fill"
        case "pending": return "circle"
        default: return "circle.dotted"
        }
    }

    private func color(for status: String) -> Color {
        switch ToolUseTodoParser.normalizedStatus(status) {
        case "in_progress": return .blue
        case "completed": return .green
        case "pending": return .orange
        default: return .secondary
        }
    }
}

struct TodoToolCardDetailSheetView: View {
    let context: ToolCardRenderContext
    let loadState: ToolCardDetailLoadState
    let onClose: () -> Void

    private var todoItems: [TodoItemSnapshot] {
        let fromOutput = ToolUseTodoParser.parseItems(from: context.resolvedOutput)
        if !fromOutput.isEmpty {
            return fromOutput
        }
        return ToolUseTodoParser.parseItems(from: context.resolvedInput)
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

                    if let summary = ToolCardSemanticHelpers.todoProgressSummary(from: todoItems) {
                        Text(summary)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                    }

                    if todoItems.isEmpty {
                        Text("暂无 Todo 项")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(todoItems) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: icon(for: item.status))
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(color(for: item.status))
                                    .frame(width: 16)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.content)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.primary)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    HStack(spacing: 6) {
                                        Text(label(for: item.status))
                                            .font(.caption)
                                            .foregroundColor(.secondary)

                                        if let priority = item.priority, !priority.isEmpty {
                                            Text("优先级: \(priority)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                }
                            }
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(.secondarySystemBackground))
                            )
                        }
                    }

                    if let input = context.resolvedInput,
                       !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSection(title: "输入 payload", icon: "arrow.down.circle", copyText: input) {
                            CodeBlock(text: ToolCardSemanticHelpers.prettyPrintedJSONIfPossible(input))
                        }
                    }

                    if let output = context.resolvedOutput,
                       !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSection(title: "输出 payload", icon: "arrow.up.circle", copyText: output) {
                            if context.toolUse.status == .error {
                                ErrorBlock(text: output)
                            } else {
                                CodeBlock(text: ToolCardSemanticHelpers.prettyPrintedJSONIfPossible(output))
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("计划详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", action: onClose)
                }
            }
        }
    }

    private func icon(for status: String) -> String {
        switch ToolUseTodoParser.normalizedStatus(status) {
        case "in_progress": return "arrow.triangle.2.circlepath"
        case "completed": return "checkmark.circle.fill"
        case "pending": return "circle"
        default: return "circle.dotted"
        }
    }

    private func color(for status: String) -> Color {
        switch ToolUseTodoParser.normalizedStatus(status) {
        case "in_progress": return .blue
        case "completed": return .green
        case "pending": return .orange
        default: return .secondary
        }
    }

    private func label(for status: String) -> String {
        switch ToolUseTodoParser.normalizedStatus(status) {
        case "in_progress": return "进行中"
        case "completed": return "已完成"
        case "pending": return "待办"
        default: return status
        }
    }
}

extension TodoToolCardContentView {
    static func summaryText(for context: ToolCardRenderContext) -> String {
        let outputItems = ToolUseTodoParser.parseItems(from: context.resolvedOutput)
        if let summary = ToolCardSemanticHelpers.todoProgressSummary(from: outputItems) {
            return summary
        }

        let inputItems = ToolUseTodoParser.parseItems(from: context.resolvedInput)
        if let summary = ToolCardSemanticHelpers.todoProgressSummary(from: inputItems) {
            return summary
        }

        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: output)
        }

        return "计划更新"
    }
}
