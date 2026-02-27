//
//  ToolCardPrimitives.swift
//  contextgo
//
//  Shared primitives for CLI tool cards.
//

import Foundation
import SwiftUI
import UIKit

// MARK: - Status Badge

struct StatusBadge: View {
    let status: CLIMessage.ToolUse.Status

    var body: some View {
        HStack(spacing: 4) {
            if status == .running, UIRenderPerformance.allowsSpinnerAnimation {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.7)
            } else {
                Image(systemName: statusIcon)
                    .font(.system(size: 12, weight: .semibold))
            }

            Text(statusText)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(statusColor)
        )
    }

    private var statusIcon: String {
        switch status {
        case .pending: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var statusText: String {
        switch status {
        case .pending: return "等待中"
        case .running: return "运行中"
        case .success: return "成功"
        case .error: return "失败"
        }
    }

    private var statusColor: Color {
        switch status {
        case .pending: return .orange
        case .running: return .blue
        case .success: return .green
        case .error: return .red
        }
    }
}

// MARK: - Detail Section

struct DetailSection<Content: View>: View {
    let title: String
    let icon: String
    let copyText: String?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        icon: String,
        copyText: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.copyText = copyText
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))

                Spacer(minLength: 4)

                if let copyText,
                   !copyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    CopyTextButton(text: copyText)
                }
            }
            .foregroundColor(.secondary)

            content()
        }
    }
}

struct CopyTextButton: View {
    let text: String
    @State private var didCopy = false

    var body: some View {
        Button {
            performCopy()
        } label: {
            Image(systemName: didCopy ? "checkmark.circle.fill" : "doc.on.doc")
                .font(.caption)
                .foregroundColor(didCopy ? .green : .secondary)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("复制")
    }

    private func performCopy() {
        let payload = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
            return
        }

        UIPasteboard.general.string = payload
        let copied = (UIPasteboard.general.string == payload)

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(copied ? .success : .warning)

        guard copied else { return }

        withAnimation(.easeInOut(duration: 0.15)) {
            didCopy = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopy = false
            }
        }
    }
}

struct TextCopyButton: View {
    let text: String
    let label: String
    @State private var didCopy = false

    var body: some View {
        Button {
            performCopy()
        } label: {
            Text(didCopy ? "已复制" : label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(didCopy ? .green : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color(.systemGray5))
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func performCopy() {
        let payload = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.warning)
            return
        }

        UIPasteboard.general.string = payload
        let copied = (UIPasteboard.general.string == payload)

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(copied ? .success : .warning)

        guard copied else { return }

        withAnimation(.easeInOut(duration: 0.15)) {
            didCopy = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopy = false
            }
        }
    }
}

// MARK: - Code Block

struct CodeBlock: View {
    let text: String

    private var displayText: String {
        // Keep cross-tool output alignment stable: normalize tabs first, then
        // normalize accidental wrapper indentation for line-numbered snippets.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
        return Self.normalizeLineNumberIndentIfNeeded(normalized)
    }

    private static let numberedLineRegex: NSRegularExpression? = try? NSRegularExpression(
        // Examples:
        // "116: foo", "116    foo", "  116    foo"
        pattern: #"^\s*\d+(?:\s*:|\s+\S)"#,
        options: []
    )

    private static func normalizeLineNumberIndentIfNeeded(_ raw: String) -> String {
        let lines = raw.components(separatedBy: "\n")
        guard lines.count > 1 else { return raw }

        let nonEmptyIndexes = lines.indices.filter { index in
            !lines[index].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard nonEmptyIndexes.count > 1 else { return raw }

        // Fast path: whole block is a numbered snippet.
        if allLinesLookNumbered(lines, indexes: nonEmptyIndexes),
           let normalized = normalizeNumberedLineIndexes(nonEmptyIndexes, in: lines) {
            return normalized.joined(separator: "\n")
        }

        // Mixed blocks (e.g. "exitCode: 0" + numbered content):
        // normalize each contiguous numbered run independently.
        let runs = numberedLineRuns(in: lines)
        guard !runs.isEmpty else { return raw }

        var updated = lines
        var changed = false
        for run in runs where run.count > 1 {
            guard let normalizedRun = normalizeNumberedLineIndexes(run, in: updated) else { continue }
            for index in run where updated.indices.contains(index) {
                if updated[index] != normalizedRun[index] {
                    updated[index] = normalizedRun[index]
                    changed = true
                }
            }
        }

        return changed ? updated.joined(separator: "\n") : raw
    }

    private static func allLinesLookNumbered(_ lines: [String], indexes: [Int]) -> Bool {
        guard !indexes.isEmpty else { return false }
        return indexes.allSatisfy { index in
            isNumberedLine(lines[index])
        }
    }

    private static func isNumberedLine(_ line: String) -> Bool {
        guard let regex = numberedLineRegex else { return false }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return regex.firstMatch(in: line, options: [], range: range) != nil
    }

    private static func numberedLineRuns(in lines: [String]) -> [[Int]] {
        var runs: [[Int]] = []
        var current: [Int] = []

        for index in lines.indices {
            if isNumberedLine(lines[index]) {
                current.append(index)
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty {
            runs.append(current)
        }

        return runs
    }

    private static func normalizeNumberedLineIndexes(_ indexes: [Int], in lines: [String]) -> [String]? {
        guard indexes.count > 1 else { return nil }
        var updated = lines

        let firstIndex = indexes[0]
        let trailingIndexes = Array(indexes.dropFirst())

        // If first numbered line is flush-left, strip shared wrapper indent from trailing lines.
        if !lineHasLeadingWhitespace(updated[firstIndex]),
           let trailingIndent = commonLeadingWhitespace(for: trailingIndexes, in: updated),
           !trailingIndent.isEmpty {
            for index in trailingIndexes where updated[index].hasPrefix(trailingIndent) {
                updated[index].removeFirst(trailingIndent.count)
            }
            return updated
        }

        // Otherwise strip any shared wrapper indent across the whole numbered run.
        if let commonIndent = commonLeadingWhitespace(for: indexes, in: updated),
           !commonIndent.isEmpty {
            return stripLeadingWhitespace(commonIndent, in: updated, indexes: indexes)
        }

        return nil
    }

    private static func lineHasLeadingWhitespace(_ line: String) -> Bool {
        guard let first = line.first else { return false }
        return first == " " || first == "\t"
    }

    private static func leadingWhitespace(of line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" })
    }

    private static func commonLeadingWhitespace(for indexes: [Int], in lines: [String]) -> String? {
        guard let firstIndex = indexes.first else { return nil }
        var common = leadingWhitespace(of: lines[firstIndex])
        guard !common.isEmpty else { return nil }

        for index in indexes.dropFirst() {
            let current = leadingWhitespace(of: lines[index])
            while !common.isEmpty && !current.hasPrefix(common) {
                common.removeLast()
            }
            if common.isEmpty {
                return nil
            }
        }

        return common
    }

    private static func stripLeadingWhitespace(
        _ prefix: String,
        in lines: [String],
        indexes: [Int]
    ) -> [String] {
        guard !prefix.isEmpty else { return lines }
        var updated = lines
        for index in indexes where updated.indices.contains(index) {
            if updated[index].hasPrefix(prefix) {
                updated[index].removeFirst(prefix.count)
            }
        }
        return updated
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(displayText)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.primary)
                .padding(8)
                .textSelection(.enabled)
        }
        .background(codeBlockBackground)
    }

    @ViewBuilder
    private var codeBlockBackground: some View {
        if UIRenderPerformance.highPerformanceModeEnabled {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.secondarySystemBackground))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.2), lineWidth: 1)
                )
        }
    }
}

// MARK: - Error Block

struct ErrorBlock: View {
    let text: String

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.red)
                .padding(8)
                .textSelection(.enabled)
        }
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(UIRenderPerformance.highPerformanceModeEnabled ? Color.red.opacity(0.08) : Color.red.opacity(0.1))
                .overlay {
                    if !UIRenderPerformance.highPerformanceModeEnabled {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.red.opacity(0.3), lineWidth: 1)
                    }
                }
        )
    }
}

// MARK: - SkillGet Card Helpers

struct SkillGetPreviewBlock: View {
    let snapshot: SkillGetCardSnapshot?
    let fallbackText: String

    private var resolvedName: String? {
        let value = snapshot?.skillName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private var resolvedURI: String? {
        let value = snapshot?.skillUri?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }

    private var resolvedDescription: String {
        let value = snapshot?.descriptionPreview?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !value.isEmpty {
            return value
        }
        return fallbackText
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = resolvedName {
                Text(name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
            }

            if let uri = resolvedURI {
                HStack(alignment: .top, spacing: 6) {
                    Text("URI")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                    Text(uri)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Text(resolvedDescription)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)

            if snapshot?.hasSidecarPayload == true {
                Text("点击详情可旁路加载完整技能描述")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct SkillListPreviewBlock: View {
    let snapshot: SkillListCardSnapshot?
    let fallbackText: String

    private var titleText: String {
        guard let snapshot else { return fallbackText }
        if snapshot.totalCount > 0 {
            return "共 \(snapshot.totalCount) 个技能"
        }
        return fallbackText
    }

    private var previewLabels: [String] {
        guard let snapshot else { return [] }
        if !snapshot.previewNames.isEmpty {
            return snapshot.previewNames
        }
        return snapshot.previewUris.map { uri in
            let tail = uri.split(separator: "/").last.map(String.init) ?? uri
            return tail
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(titleText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(1)

            if !previewLabels.isEmpty {
                HStack(spacing: 6) {
                    ForEach(previewLabels, id: \.self) { label in
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
            }

            if snapshot?.hasSidecarPayload == true {
                Text("详情可能在侧载文件中，点开详情可查看原始结果")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct SkillCreatePreviewBlock: View {
    let snapshot: SkillCreateCardSnapshot?
    let fallbackText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let name = snapshot?.skillName,
               !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                HStack(spacing: 6) {
                    Text(snapshot?.overwritten == true ? "覆盖更新" : "已创建")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(snapshot?.overwritten == true ? .orange : .green)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background((snapshot?.overwritten == true ? Color.orange : Color.green).opacity(0.15))
                        .clipShape(Capsule())
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
            }

            if let description = snapshot?.descriptionPreview,
               !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            } else {
                Text(fallbackText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            if let uri = snapshot?.skillUri,
               !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(uri)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}

struct SkillDeletePreviewBlock: View {
    let snapshot: SkillDeleteCardSnapshot?
    let fallbackText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("已删除")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.red)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.red.opacity(0.14))
                    .clipShape(Capsule())
                if let name = snapshot?.skillName,
                   !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
            }

            if let uri = snapshot?.skillUri,
               !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(uri)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text(fallbackText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

struct SkillListToolDetailSheet: View {
    let toolUse: CLIMessage.ToolUse

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var detail: SkillListCardDetail?
    @State private var errorMessage: String?

    private var titleText: String {
        if let detail {
            return "技能列表（\(detail.totalCount)）"
        }
        return "技能列表详情"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isLoading {
                        ProgressView("加载技能列表...")
                    }

                    if let errorMessage,
                       !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ErrorBlock(text: errorMessage)
                    }

                    if let detail {
                        ForEach(detail.entries) { entry in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.skillName)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(.primary)

                                if let description = entry.description,
                                   !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(description)
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                if let uri = entry.skillUri,
                                   !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    Text(uri)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }

                        if detail.loadedFromSidecar,
                           let ref = detail.sidecarRef,
                           !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            DetailSection(title: "侧载来源", icon: "externaldrive", copyText: ref) {
                                Text(ref)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            guard detail == nil, !isLoading else { return }
            isLoading = true
            defer { isLoading = false }

            guard ToolCardSemanticHelpers.isSkillListToolName(toolUse.name) else {
                errorMessage = "当前工具不是 skill_list。"
                return
            }

            if let loaded = ToolCardSemanticHelpers.loadSkillListDetail(for: toolUse) {
                detail = loaded
            } else {
                errorMessage = "未解析到技能列表详情，可能该轮结果未返回可识别数据。"
            }
        }
    }
}

struct SkillGetToolDetailSheet: View {
    let toolUse: CLIMessage.ToolUse

    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var detail: SkillGetCardDetail?
    @State private var errorMessage: String?

    private var titleText: String {
        let resolved = detail?.skillName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !resolved.isEmpty {
            return resolved
        }
        return "技能详情"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if isLoading {
                        ProgressView("加载技能详情...")
                    }

                    if let errorMessage,
                       !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        ErrorBlock(text: errorMessage)
                    }

                    if let detail {
                        if let uri = detail.skillUri,
                           !uri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            DetailSection(title: "技能 URI", icon: "link", copyText: uri) {
                                Text(uri)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundColor(.primary)
                                    .textSelection(.enabled)
                            }
                        }

                        if let description = detail.description,
                           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            DetailSection(title: "描述", icon: "text.quote", copyText: description) {
                                Text(description)
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }

                        if let prompt = detail.promptTemplate,
                           !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            DetailSection(title: "完整技能描述", icon: "doc.text.magnifyingglass", copyText: prompt) {
                                CodeBlock(text: prompt)
                            }
                        }

                        if detail.loadedFromSidecar,
                           let ref = detail.sidecarRef,
                           !ref.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            DetailSection(title: "侧载来源", icon: "externaldrive", copyText: ref) {
                                Text(ref)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                .padding(16)
            }
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            guard detail == nil, !isLoading else { return }
            isLoading = true
            defer { isLoading = false }

            guard ToolCardSemanticHelpers.isSkillGetToolName(toolUse.name) else {
                errorMessage = "当前工具不是 skill_get。"
                return
            }

            if let loaded = ToolCardSemanticHelpers.loadSkillGetDetail(for: toolUse) {
                detail = loaded
            } else {
                errorMessage = "未解析到技能详情，可能该轮结果未返回技能数据。"
            }
        }
    }
}

// MARK: - Extension: ToolUse
