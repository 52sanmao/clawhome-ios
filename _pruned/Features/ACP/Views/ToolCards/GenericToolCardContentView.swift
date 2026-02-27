//
//  GenericToolCardContentView.swift
//  contextgo
//
//  Generic / fallback tool card renderer.
//

import SwiftUI

struct GenericToolCardContentView: View {
    let context: ToolCardRenderContext
    let onOpenDetail: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let description = context.toolUse.description,
               !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                DetailSection(title: "说明", icon: "text.quote") {
                    Text(description)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let input = context.resolvedInput,
               shouldShowPayload(input) {
                DetailSection(title: "输入", icon: "arrow.down.circle", copyText: input) {
                    CodeBlock(text: ToolCardSemanticHelpers.prettyPrintedJSONIfPossible(input))
                }
            }

            if let output = context.resolvedOutput,
               shouldShowPayload(output) {
                DetailSection(title: "输出", icon: "arrow.up.circle", copyText: output) {
                    if context.toolUse.status == .error {
                        ErrorBlock(text: output)
                    } else {
                        CodeBlock(text: ToolCardSemanticHelpers.readableToolOutput(output))
                    }
                }
            }

            if let onOpenDetail {
                Button(action: onOpenDetail) {
                    Label("查看完整详情", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func shouldShowPayload(_ raw: String) -> Bool {
        !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct GenericToolCardDetailSheetView: View {
    let context: ToolCardRenderContext
    let loadState: ToolCardDetailLoadState
    let onClose: () -> Void

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

                    if context.semanticKind == .parallelDispatch {
                        ParallelDispatchToolCardContentView(context: context)
                    }

                    if let description = context.toolUse.description,
                       !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        DetailSection(title: "说明", icon: "text.quote", copyText: description) {
                            Text(description)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if let input = context.resolvedInput,
                       !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       context.semanticKind != .parallelDispatch {
                        DetailSection(title: "输入", icon: "arrow.down.circle", copyText: input) {
                            CodeBlock(text: ToolCardSemanticHelpers.prettyPrintedJSONIfPossible(input))
                        }
                    }

                    if let output = context.resolvedOutput,
                       !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       context.semanticKind != .parallelDispatch {
                        DetailSection(title: "输出", icon: "arrow.up.circle", copyText: output) {
                            if context.toolUse.status == .error {
                                ErrorBlock(text: output)
                            } else {
                                CodeBlock(text: ToolCardSemanticHelpers.readableToolOutput(output))
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle("工具详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭", action: onClose)
                }
            }
        }
    }
}

extension GenericToolCardContentView {
    static func summaryText(for context: ToolCardRenderContext) -> String {
        if context.semanticKind == .read,
           let readSummary = ToolCardSemanticHelpers.summarizeReadPayload(from: context.resolvedOutput)
            ?? ToolCardSemanticHelpers.summarizeReadPayload(from: context.resolvedInput),
           !readSummary.isEmpty {
            return readSummary
        }

        if context.semanticKind == .titleChange,
           let changed = ToolCardSemanticHelpers.extractChangedTitle(from: context.resolvedOutput)
            ?? ToolCardSemanticHelpers.extractChangedTitle(from: context.resolvedInput),
           !changed.isEmpty {
            return "标题: \(changed)"
        }

        if context.semanticKind == .fileEdit,
           let summary = summarizeFileEdit(from: context.resolvedOutput)
            ?? summarizeFileEdit(from: context.resolvedInput),
           !summary.isEmpty {
            return summary
        }

        if let output = context.resolvedOutput,
           !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: output)
        }

        if let input = context.resolvedInput,
           !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ToolCardSemanticHelpers.firstMeaningfulLine(from: input)
        }

        return context.toolUse.name
    }

    private static func summarizeFileEdit(from raw: String?) -> String? {
        guard let raw else { return nil }

        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }

        let fileLines = lines.filter { line in
            if line.hasPrefix("M ") || line.hasPrefix("A ") || line.hasPrefix("D ") || line.hasPrefix("R ") {
                return true
            }
            return line.hasPrefix("contextgo/") || line.hasPrefix("src/") || line.hasPrefix("docs/")
        }

        if !fileLines.isEmpty {
            let first = fileLines[0]
            if fileLines.count == 1 {
                return "已更新: \(first)"
            }
            return "已更新 \(fileLines.count) 个文件（含 \(first)）"
        }

        if let signal = lines.first(where: { $0.lowercased().contains("updated the following files") }) {
            return signal
        }

        return nil
    }
}
