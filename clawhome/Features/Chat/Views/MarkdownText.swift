//
//  MarkdownText.swift
//  contextgo
//
//  Markdown renderer using MarkdownUI library
//  Provides professional rendering with proper spacing and styling
//

import Foundation
import SwiftUI
import MarkdownUI

struct MarkdownText: View, Equatable {
    enum HeadingStyle: Equatable {
        case standard
        case compact
    }

    let markdown: String
    let isUserMessage: Bool
    let allowPlainTextFallback: Bool
    let headingStyle: HeadingStyle

    @Environment(\.colorScheme) private var colorScheme

    init(
        markdown: String,
        isUserMessage: Bool,
        allowPlainTextFallback: Bool = false,
        headingStyle: HeadingStyle = .standard
    ) {
        self.markdown = markdown
        self.isUserMessage = isUserMessage
        self.allowPlainTextFallback = allowPlainTextFallback
        self.headingStyle = headingStyle
    }

    static func == (lhs: MarkdownText, rhs: MarkdownText) -> Bool {
        lhs.markdown == rhs.markdown
            && lhs.isUserMessage == rhs.isUserMessage
            && lhs.allowPlainTextFallback == rhs.allowPlainTextFallback
            && lhs.headingStyle == rhs.headingStyle
    }

    private static let lightThemeStandard: MarkdownUI.Theme = buildTheme(isDark: false, headingStyle: .standard)
    private static let darkThemeStandard: MarkdownUI.Theme = buildTheme(isDark: true, headingStyle: .standard)
    private static let lightThemeCompact: MarkdownUI.Theme = buildTheme(isDark: false, headingStyle: .compact)
    private static let darkThemeCompact: MarkdownUI.Theme = buildTheme(isDark: true, headingStyle: .compact)
    private static let plainTextDecisionCache: NSCache<NSString, NSNumber> = {
        let cache = NSCache<NSString, NSNumber>()
        cache.countLimit = 1024
        return cache
    }()

    // Custom theme with enhanced code block styling
    private var customTheme: MarkdownUI.Theme {
        switch (headingStyle, colorScheme) {
        case (.compact, .dark):
            Self.darkThemeCompact
        case (.compact, _):
            Self.lightThemeCompact
        case (.standard, .dark):
            Self.darkThemeStandard
        case (.standard, _):
            Self.lightThemeStandard
        }
    }

    private static func buildTheme(isDark: Bool, headingStyle: HeadingStyle) -> MarkdownUI.Theme {
        let isCompact = headingStyle == .compact
        let heading1Size: Double = isCompact ? 1.35 : 2.0
        let heading2Size: Double = isCompact ? 1.15 : 1.5
        let heading3Size: Double = isCompact ? 1.05 : 1.25
        let heading1Top: Double = isCompact ? 0.5 : 0.8
        let heading2Top: Double = isCompact ? 0.45 : 0.7
        let heading3Top: Double = isCompact ? 0.4 : 0.6
        let headingBottom: Double = isCompact ? 0.22 : 0.3

        return MarkdownUI.Theme()
            .codeBlock { configuration in
                VStack(alignment: .leading, spacing: 0) {
                    // Language label and copy button header
                    HStack {
                        if let language = configuration.language, !language.isEmpty {
                            Text(language)
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                                )
                        }

                        Spacer()

                        // Copy button
                        Button(action: {
                            UIPasteboard.general.string = configuration.content
                            let generator = UIImpactFeedbackGenerator(style: .light)
                            generator.impactOccurred()
                        }) {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                                Text("复制")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isDark ? Color.white.opacity(0.1) : Color.black.opacity(0.05))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(isDark ? Color(.systemGray5).opacity(0.5) : Color(.systemGray6))

                    Divider()

                    // Code content with horizontal scrolling
                    ScrollView(.horizontal, showsIndicators: false) {
                        configuration.label
                            .relativeLineSpacing(.em(0.2))
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(.em(0.85))
                                ForegroundColor(isDark ? .white.opacity(0.9) : .black.opacity(0.85))
                            }
                            .padding(12)
                    }
                    .background(isDark ? Color(.systemGray6).opacity(0.3) : Color(.systemGray6))
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isDark ? Color.white.opacity(0.1) : Color.gray.opacity(0.2), lineWidth: 1)
                )
            }
            .code {
                // Inline code style - using more subtle colors
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                ForegroundColor(isDark ? Color(.systemPink).opacity(0.9) : Color(.systemIndigo))
                BackgroundColor(isDark ? Color(.systemGray6).opacity(0.5) : Color(.systemGray5).opacity(0.8))
            }
            .paragraph { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.25))
                    .markdownMargin(top: .zero, bottom: .em(0.8))
            }
            .heading1 { configuration in
                configuration.label
                    .relativePadding(.bottom, length: .em(headingBottom))
                    .relativeLineSpacing(.em(0.125))
                    .markdownMargin(top: .em(heading1Top), bottom: .em(isCompact ? 0.32 : 0.5))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(heading1Size))
                    }
            }
            .heading2 { configuration in
                configuration.label
                    .relativePadding(.bottom, length: .em(headingBottom))
                    .relativeLineSpacing(.em(0.125))
                    .markdownMargin(top: .em(heading2Top), bottom: .em(isCompact ? 0.28 : 0.4))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(heading2Size))
                    }
            }
            .heading3 { configuration in
                configuration.label
                    .relativeLineSpacing(.em(0.125))
                    .markdownMargin(top: .em(heading3Top), bottom: .em(isCompact ? 0.24 : 0.3))
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(.em(heading3Size))
                    }
            }
            .table { configuration in
                configuration.label
                    .fixedSize(horizontal: false, vertical: true)
                    .markdownTableBorderStyle(.init(color: isDark ? Color.white.opacity(0.2) : Color.gray.opacity(0.3)))
                    .markdownTableBackgroundStyle(
                        .alternatingRows(isDark ? Color(.systemGray6).opacity(0.3) : Color(.systemGray6), .clear)
                    )
                    .markdownMargin(top: .em(0.8), bottom: .em(0.8))
            }
            .tableCell { configuration in
                configuration.label
                    .markdownTextStyle {
                        if configuration.row == 0 {
                            FontWeight(.semibold)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: .em(0.25))
            }
            .blockquote { configuration in
                HStack(alignment: .top, spacing: 0) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isDark ? Color.white.opacity(0.3) : Color.gray.opacity(0.4))
                        .frame(width: 4)
                    configuration.label
                        .relativePadding(.leading, length: .em(1))
                        .markdownTextStyle {
                            ForegroundColor(.secondary)
                        }
                }
                .markdownMargin(top: .em(0.8), bottom: .em(0.8))
            }
    }

    var body: some View {
        let normalizedMarkdownValue = normalizeEscapedMarkdownIfNeeded(markdown)
        Group {
            if allowPlainTextFallback && shouldUsePlainTextFallback(normalizedMarkdownValue) {
                Text(normalizedMarkdownValue)
                    .font(.system(size: 14))
                    .foregroundColor(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                Markdown(normalizedMarkdownValue)
                    .markdownTheme(customTheme)
                    .markdownTextStyle {
                        // Override text color for user messages to ensure visibility
                        if isUserMessage {
                            ForegroundColor(.primary)
                        }
                    }
                    .textSelection(.enabled)
                    .frame(maxWidth: isUserMessage ? nil : .infinity, alignment: .leading)
            }
        }
    }

    private func normalizeEscapedMarkdownIfNeeded(_ text: String) -> String {
        let escapedNewlineCount = text.components(separatedBy: "\\n").count - 1
        let hasEscapedMarkdownToken =
            text.contains("\\*\\*")
            || text.contains("\\`\\`\\`")
            || text.contains("\\#")
            || text.contains("\\-")
            || text.contains("\\_")
        let hasActualNewline = text.contains("\n")

        // Only unescape when content strongly looks double-escaped.
        let shouldUnescape = (escapedNewlineCount > 0 && !hasActualNewline) || hasEscapedMarkdownToken
        guard shouldUnescape else { return text }

        var normalized = text
        normalized = normalized.replacingOccurrences(of: "\\r\\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\\n", with: "\n")
        normalized = normalized.replacingOccurrences(of: "\\t", with: "\t")
        normalized = normalized.replacingOccurrences(of: "\\\"", with: "\"")
        normalized = normalized.replacingOccurrences(of: "\\`", with: "`")
        normalized = normalized.replacingOccurrences(of: "\\*", with: "*")
        normalized = normalized.replacingOccurrences(of: "\\_", with: "_")
        normalized = normalized.replacingOccurrences(of: "\\[", with: "[")
        normalized = normalized.replacingOccurrences(of: "\\]", with: "]")
        normalized = normalized.replacingOccurrences(of: "\\(", with: "(")
        normalized = normalized.replacingOccurrences(of: "\\)", with: ")")
        normalized = normalized.replacingOccurrences(of: "\\#", with: "#")
        normalized = normalized.replacingOccurrences(of: "\\-", with: "-")
        return normalized
    }

    private func shouldUsePlainTextFallback(_ text: String) -> Bool {
        let key = text as NSString
        if let cached = Self.plainTextDecisionCache.object(forKey: key) {
            return cached.boolValue
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lineCount = text.utf8.reduce(into: 1) { count, value in
            if value == 10 { count += 1 }
        }
        let looksLikeJSON = trimmed.hasPrefix("{")
            || trimmed.hasPrefix("[")
            || trimmed.hasPrefix("```json")
            || trimmed.hasPrefix("```JSON")

        let result: Bool
        if text.count > 10_000 {
            result = true
        } else if lineCount > 360 {
            result = true
        } else if looksLikeJSON && (text.count > 1_200 || lineCount > 90) {
            result = true
        } else {
            result = text.contains("```") && text.count > 5_000
        }

        Self.plainTextDecisionCache.setObject(NSNumber(value: result), forKey: key)
        return result
    }
}

// MARK: - Preview

#Preview("AI Message with Headers") {
    VStack(alignment: .leading, spacing: 20) {
        // AI message with various Markdown elements
        MarkdownText(
            markdown: """
            # 大标题

            这是一个段落，包含一些**粗体文字**和*斜体文字*。

            ## 二级标题

            这是另一个段落，包含 `代码片段` 和[链接](https://example.com)。

            ### 列表示例

            - 项目 1
            - 项目 2
            - 项目 3

            ### 代码块示例

            ```swift
            func greet(name: String) {
                print("Hello, \\(name)!")
            }
            ```

            这是最后一段文字。
            """,
            isUserMessage: false
        )
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)

        // User message
        MarkdownText(
            markdown: """
            这是用户消息，包含**加粗**文字。

            还有一段代码：`let x = 10`
            """,
            isUserMessage: true
        )
        .padding()
        .background(Color.blue)
        .cornerRadius(12)
        .foregroundColor(.white)
    }
    .padding()
}

#Preview("Code Heavy Message") {
    VStack(alignment: .leading) {
        MarkdownText(
            markdown: """
            下面是一个 Python 示例：

            ```python
            def fibonacci(n):
                if n <= 1:
                    return n
                return fibonacci(n-1) + fibonacci(n-2)

            print(fibonacci(10))
            ```

            这段代码计算斐波那契数列。
            """,
            isUserMessage: false
        )
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    .padding()
}

#Preview("Table Example") {
    VStack(alignment: .leading) {
        MarkdownText(
            markdown: """
            ## 功能对比

            | 功能 | 旧版本 | 新版本 |
            |------|--------|--------|
            | 标题渲染 | ⚠️ 不完整 | ✅ 完整 |
            | 段落间距 | ⚠️ 需手动 | ✅ 自动 |
            | 表格支持 | ❌ 不支持 | ✅ 支持 |

            表格渲染效果很棒！
            """,
            isUserMessage: false
        )
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    .padding()
}

#Preview("Quote and List") {
    VStack(alignment: .leading) {
        MarkdownText(
            markdown: """
            > 这是一段引用文字，可以用来强调重要内容。

            **代办事项：**

            1. 完成 Markdown 集成
            2. 测试各种格式
            3. 优化样式主题

            **注意事项：**

            - 确保所有格式正确渲染
            - 检查深色模式兼容性
            - 验证用户消息样式
            """,
            isUserMessage: false
        )
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
    .padding()
}
