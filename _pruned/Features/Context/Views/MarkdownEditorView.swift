//
//  MarkdownEditorView.swift
//  contextgo
//
//  Notes-like Markdown editor for Context review editing.
//

import SwiftUI
import MarkdownUI
import UIKit

private enum MarkdownEditorSaveState: Equatable {
    case clean
    case dirty
    case saving
    case saved
    case failed(String)
}

// MARK: - Full Screen Markdown Editor

struct MarkdownEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @Binding var content: String
    let title: String
    let onSave: ((String) async throws -> Void)?

    @State private var editorContent: String
    @State private var selectedRange: NSRange
    @State private var showDiscardAlert = false
    @State private var showPreviewSheet = false
    @State private var saveState: MarkdownEditorSaveState = .clean
    @State private var isApplyingAutoContinuation = false
    @State private var lastSavedAt: Date?

    init(content: Binding<String>, title: String, onSave: ((String) async throws -> Void)? = nil) {
        self._content = content
        self.title = title
        self.onSave = onSave
        let initial = content.wrappedValue
        self._editorContent = State(initialValue: initial)
        self._selectedRange = State(initialValue: NSRange(location: (initial as NSString).length, length: 0))
    }

    private var themeBackground: Color {
        colorScheme == .dark ? Color.black : Color(.systemBackground)
    }

    private var hasUnsavedChanges: Bool {
        editorContent != content
    }

    private var lineCount: Int {
        max(1, editorContent.split(separator: "\n", omittingEmptySubsequences: false).count)
    }

    private var wordCount: Int {
        editorContent
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }

    private var canSave: Bool {
        hasUnsavedChanges && saveState != .saving
    }

    private var saveStateLabel: String {
        switch saveState {
        case .clean:
            return "无改动"
        case .dirty:
            return "未保存"
        case .saving:
            return "保存中..."
        case .saved:
            if let lastSavedAt {
                return "已保存 \(Self.timeFormatter.string(from: lastSavedAt))"
            }
            return "已保存"
        case let .failed(message):
            return "保存失败: \(message)"
        }
    }

    private var saveStateColor: Color {
        switch saveState {
        case .clean, .saved:
            return .green
        case .dirty:
            return .orange
        case .saving:
            return .blue
        case .failed:
            return .red
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                headerStateBar
                Divider()

                MarkdownEditorTextView(text: $editorContent, selectedRange: $selectedRange)
                    .background(themeBackground)
                    .onChange(of: editorContent) { oldValue, newValue in
                        handleContentChange(oldValue: oldValue, newValue: newValue)
                    }

                Divider()

                HStack {
                    Label("\(lineCount) 行", systemImage: "list.number")
                    Spacer()
                    Label("\(wordCount) 词", systemImage: "textformat.abc")
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemBackground))
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        if hasUnsavedChanges {
                            showDiscardAlert = true
                        } else {
                            dismiss()
                        }
                    }
                }

                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showPreviewSheet = true
                    } label: {
                        Image(systemName: "eye")
                    }

                    Button {
                        Task { await performSave() }
                    } label: {
                        if saveState == .saving {
                            ProgressView()
                        } else {
                            Text("保存")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(!canSave)
                }

                ToolbarItemGroup(placement: .keyboard) {
                    Button(action: applyHeadingPrefix) {
                        Image(systemName: "textformat.size")
                    }
                    .help("标题")

                    Button(action: applyBulletPrefix) {
                        Image(systemName: "list.bullet")
                    }
                    .help("无序列表")

                    Button(action: applyTodoPrefix) {
                        Image(systemName: "checklist")
                    }
                    .help("任务列表")

                    Button(action: applyQuotePrefix) {
                        Image(systemName: "text.quote")
                    }
                    .help("引用")

                    Button(action: insertCodeBlock) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                    }
                    .help("代码块")

                    Spacer()

                    Button("完成") {
                        hideKeyboard()
                    }
                }
            }
            .sheet(isPresented: $showPreviewSheet) {
                previewSheet
            }
            .alert("放弃更改？", isPresented: $showDiscardAlert) {
                Button("继续编辑", role: .cancel) {}
                Button("放弃", role: .destructive) {
                    dismiss()
                }
            } message: {
                Text("你有未保存的更改，关闭后将丢失。")
            }
        }
    }

    private var headerStateBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(saveStateColor)
                .frame(width: 8, height: 8)

            Text(saveStateLabel)
                .font(.footnote)
                .foregroundColor(.secondary)
                .lineLimit(1)

            Spacer()

            if case .failed = saveState {
                Button("重试") {
                    Task { await performSave() }
                }
                .font(.footnote.weight(.semibold))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground))
    }

    private var previewSheet: some View {
        NavigationView {
            ScrollView {
                MarkdownText(markdown: editorContent, isUserMessage: false)
                    .padding(16)
            }
            .background(themeBackground)
            .navigationTitle("预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("关闭") {
                        showPreviewSheet = false
                    }
                }
            }
        }
    }

    private func handleContentChange(oldValue: String, newValue: String) {
        guard !isApplyingAutoContinuation else { return }

        if let updated = autoContinueListIfNeeded(oldValue: oldValue, newValue: newValue) {
            isApplyingAutoContinuation = true
            editorContent = updated.text
            selectedRange = NSRange(location: updated.cursorLocation, length: 0)
            isApplyingAutoContinuation = false
        }

        if saveState != .saving {
            if editorContent == content {
                saveState = .clean
            } else if case .failed = saveState {
                saveState = .dirty
            } else if saveState != .saved {
                saveState = .dirty
            }
        }
    }

    private func performSave() async {
        guard canSave else { return }

        saveState = .saving
        let payload = editorContent

        do {
            if let onSave {
                try await onSave(payload)
            }
            await MainActor.run {
                content = payload
                lastSavedAt = Date()
                saveState = .saved
            }
        } catch {
            await MainActor.run {
                saveState = .failed(error.localizedDescription)
            }
        }
    }

    private func applyHeadingPrefix() {
        toggleCurrentLinePrefix("# ")
    }

    private func applyBulletPrefix() {
        toggleCurrentLinePrefix("- ")
    }

    private func applyTodoPrefix() {
        toggleCurrentLinePrefix("- [ ] ")
    }

    private func applyQuotePrefix() {
        toggleCurrentLinePrefix("> ")
    }

    private func toggleCurrentLinePrefix(_ prefix: String) {
        let nsText = editorContent as NSString
        guard nsText.length >= 0 else { return }

        let safeLocation = min(selectedRange.location, nsText.length)
        let rawLineRange = nsText.lineRange(for: NSRange(location: safeLocation, length: 0))
        var lineRange = rawLineRange

        // `lineRange` includes trailing newline; keep replacement scoped to visible content.
        if lineRange.length > 0 {
            let lineString = nsText.substring(with: lineRange)
            if lineString.hasSuffix("\n") {
                lineRange.length -= 1
            }
        }

        let lineText = nsText.substring(with: lineRange)
        let hasPrefix = lineText.hasPrefix(prefix)
        let newLineText = hasPrefix ? String(lineText.dropFirst(prefix.count)) : (prefix + lineText)
        let updatedText = nsText.replacingCharacters(in: lineRange, with: newLineText)

        let relativeLocation = max(0, safeLocation - lineRange.location)
        let newRelativeLocation: Int
        if hasPrefix {
            newRelativeLocation = max(0, relativeLocation - prefix.count)
        } else {
            newRelativeLocation = relativeLocation + prefix.count
        }

        editorContent = updatedText
        selectedRange = NSRange(location: lineRange.location + newRelativeLocation, length: 0)
    }

    private func insertCodeBlock() {
        let nsText = editorContent as NSString
        let safeLocation = min(selectedRange.location, nsText.length)
        let safeLength = min(selectedRange.length, nsText.length - safeLocation)
        let safeRange = NSRange(location: safeLocation, length: safeLength)

        let selectedText = nsText.substring(with: safeRange)
        let replacement: String
        let cursorLocation: Int

        if selectedText.isEmpty {
            replacement = "```\n\n```"
            cursorLocation = safeRange.location + 4
        } else {
            replacement = "```\n\(selectedText)\n```"
            cursorLocation = safeRange.location + (replacement as NSString).length
        }

        editorContent = nsText.replacingCharacters(in: safeRange, with: replacement)
        selectedRange = NSRange(location: cursorLocation, length: 0)
    }

    private func autoContinueListIfNeeded(oldValue: String, newValue: String) -> (text: String, cursorLocation: Int)? {
        // Keep behavior conservative: only auto-handle Enter inserted at the end.
        guard newValue.count == oldValue.count + 1, newValue.hasSuffix("\n") else {
            return nil
        }

        let line = oldValue.split(separator: "\n", omittingEmptySubsequences: false).last.map(String.init) ?? oldValue

        if line.isEmpty {
            return nil
        }

        if let prefix = listPrefix(of: line) {
            let body = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)

            // Empty list item + Enter => exit list mode.
            if body.isEmpty {
                if newValue.hasSuffix(prefix + "\n") {
                    let trimmed = String(newValue.dropLast(prefix.count + 1))
                    let location = (trimmed as NSString).length
                    return (trimmed, location)
                }
                return nil
            }

            // Continue same list style.
            let continued = newValue + nextListPrefix(from: prefix)
            let location = (continued as NSString).length
            return (continued, location)
        }

        return nil
    }

    private func listPrefix(of line: String) -> String? {
        if line.hasPrefix("- [ ] ") { return "- [ ] " }
        if line.hasPrefix("- [x] ") { return "- [x] " }
        if line.hasPrefix("- ") { return "- " }
        if line.hasPrefix("> ") { return "> " }

        if let range = line.range(of: "^\\d+\\. ", options: .regularExpression) {
            return String(line[range])
        }

        return nil
    }

    private func nextListPrefix(from prefix: String) -> String {
        if prefix == "- [x] " {
            return "- [ ] "
        }

        if let match = prefix.range(of: "^\\d+", options: .regularExpression),
           let number = Int(prefix[match]) {
            return "\(number + 1). "
        }

        return prefix
    }

    private func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - UITextView Wrapper

private struct MarkdownEditorTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selectedRange: NSRange

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.backgroundColor = .clear
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 24, right: 12)
        textView.adjustsFontForContentSizeCategory = true

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        paragraphStyle.paragraphSpacing = 8

        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.preferredFont(forTextStyle: .body),
            .paragraphStyle: paragraphStyle,
            .foregroundColor: UIColor.label
        ]

        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.typingAttributes = attrs
        textView.text = text
        textView.selectedRange = selectedRange
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }

        let safeLocation = min(selectedRange.location, (uiView.text as NSString).length)
        let safeLength = min(selectedRange.length, (uiView.text as NSString).length - safeLocation)
        let safeRange = NSRange(location: safeLocation, length: max(0, safeLength))
        if uiView.selectedRange != safeRange {
            uiView.selectedRange = safeRange
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownEditorTextView

        init(_ parent: MarkdownEditorTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            parent.selectedRange = textView.selectedRange
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            parent.selectedRange = textView.selectedRange
        }
    }
}

// MARK: - Preview

#Preview {
    MarkdownEditorView(
        content: .constant("""
        # Weekly Notes

        - [ ] 整理 Context 结构
        - [ ] 优化编辑器体验

        > 输入时应该像备忘录一样自然
        """),
        title: "编辑 Context"
    )
}
