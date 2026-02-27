//
//  ContextDiffView.swift
//  contextgo
//
//  Git-style diff view: compares two versions of a Context.
//  Uses Myers diff algorithm (LCS-based) for line-level diffing.
//

import SwiftUI

// MARK: - Diff Engine

enum DiffLineType {
    case unchanged
    case added
    case deleted
}

struct DiffLine: Identifiable {
    let id = UUID()
    let type: DiffLineType
    let text: String
    let oldLineNumber: Int?
    let newLineNumber: Int?
}

/// Myers diff algorithm: produces the minimum edit sequence between two line arrays.
struct DiffEngine {
    static func diff(old oldLines: [String], new newLines: [String]) -> [DiffLine] {
        let lcs = longestCommonSubsequence(oldLines, newLines)
        var result: [DiffLine] = []
        var oldIdx = 0
        var newIdx = 0
        var oldLineNum = 1
        var newLineNum = 1

        for commonLine in lcs {
            // Drain deleted lines (old side not in LCS)
            while oldIdx < oldLines.count && oldLines[oldIdx] != commonLine {
                result.append(DiffLine(
                    type: .deleted,
                    text: oldLines[oldIdx],
                    oldLineNumber: oldLineNum,
                    newLineNumber: nil
                ))
                oldIdx += 1
                oldLineNum += 1
            }
            // Drain added lines (new side not in LCS)
            while newIdx < newLines.count && newLines[newIdx] != commonLine {
                result.append(DiffLine(
                    type: .added,
                    text: newLines[newIdx],
                    oldLineNumber: nil,
                    newLineNumber: newLineNum
                ))
                newIdx += 1
                newLineNum += 1
            }
            // Common line
            result.append(DiffLine(
                type: .unchanged,
                text: commonLine,
                oldLineNumber: oldLineNum,
                newLineNumber: newLineNum
            ))
            oldIdx += 1
            newIdx += 1
            oldLineNum += 1
            newLineNum += 1
        }

        // Remaining deletions
        while oldIdx < oldLines.count {
            result.append(DiffLine(
                type: .deleted,
                text: oldLines[oldIdx],
                oldLineNumber: oldLineNum,
                newLineNumber: nil
            ))
            oldIdx += 1
            oldLineNum += 1
        }

        // Remaining additions
        while newIdx < newLines.count {
            result.append(DiffLine(
                type: .added,
                text: newLines[newIdx],
                oldLineNumber: nil,
                newLineNumber: newLineNum
            ))
            newIdx += 1
            newLineNum += 1
        }

        return result
    }

    // Standard LCS via dynamic programming
    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> [String] {
        let m = a.count
        let n = b.count
        // Use flat array for memory efficiency
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if a[i - 1] == b[j - 1] {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }

        // Backtrack
        var lcs: [String] = []
        var i = m, j = n
        while i > 0 && j > 0 {
            if a[i - 1] == b[j - 1] {
                lcs.append(a[i - 1])
                i -= 1
                j -= 1
            } else if dp[i - 1][j] > dp[i][j - 1] {
                i -= 1
            } else {
                j -= 1
            }
        }
        return lcs.reversed()
    }
}

// MARK: - Diff Stats

struct DiffStats {
    let added: Int
    let deleted: Int
    var unchanged: Int

    var hasChanges: Bool { added > 0 || deleted > 0 }
}

// MARK: - ContextDiffView

/// Full-screen diff view comparing oldContent (archived) vs newContent (current draft).
struct ContextDiffView: View {
    let title: String
    let oldContent: String   // archived version (baseline)
    let newContent: String   // current draft (new)
    let oldLabel: String
    let newLabel: String
    let onDismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var diffLines: [DiffLine] = []
    @State private var stats = DiffStats(added: 0, deleted: 0, unchanged: 0)
    @State private var showUnchanged = true

    private var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var body: some View {
        NavigationView {
            ZStack {
                theme.primaryBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Stats bar
                    if stats.hasChanges {
                        statsBar
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(theme.cardBackground)

                        Divider().background(theme.border)
                    }

                    if diffLines.isEmpty {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 44))
                                .foregroundColor(.green)
                            Text("内容完全相同")
                                .font(.headline)
                                .foregroundColor(theme.primaryText)
                            Text("两个版本没有差异")
                                .font(.subheadline)
                                .foregroundColor(theme.secondaryText)
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(filteredLines) { line in
                                    DiffLineView(line: line, colorScheme: colorScheme)
                                }
                            }
                            .padding(.bottom, 40)
                        }
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .foregroundColor(theme.primaryText)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            showUnchanged.toggle()
                        }
                    }) {
                        Label(
                            showUnchanged ? "隐藏未变" : "显示全部",
                            systemImage: showUnchanged ? "eye.slash" : "eye"
                        )
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                    }
                }
            }
        }
        .onAppear {
            computeDiff()
        }
    }

    // MARK: - Stats Bar

    private var statsBar: some View {
        HStack(spacing: 0) {
            // Version labels
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 8, height: 8)
                    Text(oldLabel)
                        .font(.caption2)
                        .foregroundColor(theme.secondaryText)
                }
                HStack(spacing: 6) {
                    Circle().fill(Color.green).frame(width: 8, height: 8)
                    Text(newLabel)
                        .font(.caption2)
                        .foregroundColor(theme.secondaryText)
                }
            }

            Spacer()

            // Change counts
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    Image(systemName: "minus")
                        .font(.caption2.bold())
                        .foregroundColor(.red)
                    Text("\(stats.deleted)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.red)
                }
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption2.bold())
                        .foregroundColor(.green)
                    Text("\(stats.added)")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.green)
                }
            }
        }
    }

    // MARK: - Filtered Lines (collapse unchanged if needed)

    private var filteredLines: [DiffLine] {
        guard !showUnchanged else { return diffLines }
        // When hiding unchanged: show context (2 lines) around changes
        var changedIndices = Set<Int>()
        for (i, line) in diffLines.enumerated() {
            if line.type != .unchanged {
                for offset in -2...2 {
                    let idx = i + offset
                    if idx >= 0 && idx < diffLines.count {
                        changedIndices.insert(idx)
                    }
                }
            }
        }
        return diffLines.enumerated().compactMap { i, line in
            changedIndices.contains(i) ? line : nil
        }
    }

    // MARK: - Compute Diff

    private func computeDiff() {
        let oldLines = oldContent.components(separatedBy: "\n")
        let newLines = newContent.components(separatedBy: "\n")

        let lines = DiffEngine.diff(old: oldLines, new: newLines)
        diffLines = lines

        var added = 0, deleted = 0, unchanged = 0
        for line in lines {
            switch line.type {
            case .added: added += 1
            case .deleted: deleted += 1
            case .unchanged: unchanged += 1
            }
        }
        stats = DiffStats(added: added, deleted: deleted, unchanged: unchanged)
    }
}

// MARK: - DiffLineView

private struct DiffLineView: View {
    let line: DiffLine
    let colorScheme: ColorScheme

    private var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    private var bgColor: Color {
        switch line.type {
        case .added:    return Color.green.opacity(colorScheme == .dark ? 0.18 : 0.12)
        case .deleted:  return Color.red.opacity(colorScheme == .dark ? 0.18 : 0.10)
        case .unchanged: return Color.clear
        }
    }

    private var prefixColor: Color {
        switch line.type {
        case .added:    return .green
        case .deleted:  return .red
        case .unchanged: return theme.tertiaryText
        }
    }

    private var prefix: String {
        switch line.type {
        case .added:    return "+"
        case .deleted:  return "-"
        case .unchanged: return " "
        }
    }

    private var lineNumColor: Color { theme.tertiaryText }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left gutter: old line number
            Text(line.oldLineNumber.map { "\($0)" } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(lineNumColor)
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 4)

            // Right gutter: new line number
            Text(line.newLineNumber.map { "\($0)" } ?? "")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(lineNumColor)
                .frame(width: 32, alignment: .trailing)
                .padding(.trailing, 6)

            // +/- prefix
            Text(prefix)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundColor(prefixColor)
                .frame(width: 14, alignment: .center)
                .padding(.trailing, 4)

            // Line content
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(line.type == .unchanged ? theme.secondaryText : theme.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 8)
        .background(bgColor)
    }
}
