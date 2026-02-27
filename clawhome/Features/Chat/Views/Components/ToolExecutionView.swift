//
//  ToolExecutionView.swift
//  contextgo
//
//  Renders tool execution events from OpenClaw Agent
//

import SwiftUI
import Foundation

struct ToolExecutionView: View {
    let tool: ToolExecution
    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tool header with icon, name, and status
            HStack(spacing: 8) {
                // Tool icon
                toolIcon
                    .font(.system(size: 16))
                    .foregroundColor(toolColor)

                // Tool name
                Text(tool.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.primary)

                if let runId = tool.runId {
                    Text(shortRunId(runId))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemGray6))
                        .clipShape(Capsule())
                }

                Spacer()

                // Status indicator
                statusBadge
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(backgroundColor.opacity(0.1))
            .cornerRadius(8)
            .onTapGesture {
                withAnimation(.spring(response: 0.3)) {
                    isExpanded.toggle()
                }
            }

            // Expandable details
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Input section
                    if let input = tool.input, !input.isEmpty {
                        ToolDetailSection(title: "参数", content: input, icon: "arrow.down.circle.fill", color: .blue)
                    }

                    // Output section
                    if let output = tool.output, !output.isEmpty {
                        ToolDetailSection(title: "输出", content: output, icon: "arrow.up.circle.fill", color: .green)
                    }

                    // Error section
                    if let error = tool.error, !error.isEmpty {
                        ToolDetailSection(title: "错误", content: error, icon: "exclamationmark.triangle.fill", color: .red)
                    }

                    // Execution time
                    HStack {
                        Image(systemName: "clock.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text(executionTimeText)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 4)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(backgroundColor.opacity(0.05))
        .cornerRadius(12)
    }

    // MARK: - Computed Properties

    private var toolIcon: Image {
        // Map tool names to SF Symbols
        switch tool.name.lowercased() {
        case "read":
            return Image(systemName: "doc.text.fill")
        case "write":
            return Image(systemName: "square.and.pencil")
        case "edit":
            return Image(systemName: "pencil.line")
        case "bash", "shell":
            return Image(systemName: "terminal.fill")
        case "glob", "find":
            return Image(systemName: "magnifyingglass")
        case "grep", "search":
            return Image(systemName: "doc.text.magnifyingglass")
        case "task":
            return Image(systemName: "list.bullet.rectangle")
        case "webfetch":
            return Image(systemName: "globe")
        case "websearch":
            return Image(systemName: "magnifyingglass.circle.fill")
        default:
            return Image(systemName: "wrench.and.screwdriver.fill")
        }
    }

    private var toolColor: Color {
        switch tool.status {
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private var backgroundColor: Color {
        switch tool.status {
        case .running:
            return .blue
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            if tool.status == .running {
                ProgressView()
                    .scaleEffect(0.7)
                    .progressViewStyle(CircularProgressViewStyle(tint: toolColor))
            } else {
                Image(systemName: tool.status == .completed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(toolColor)
            }

            Text(statusText)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(toolColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(toolColor.opacity(0.15))
        .cornerRadius(6)
    }

    private var statusText: String {
        switch tool.status {
        case .running:
            return tool.phase == .update ? "执行中" : "启动中"
        case .completed:
            return "已完成"
        case .failed:
            return "失败"
        }
    }

    private var executionTimeText: String {
        let start = tool.startTime
        if let end = tool.endTime {
            let duration = end.timeIntervalSince(start)
            return String(format: "%.2fs", duration)
        } else {
            // Still running
            let duration = Date().timeIntervalSince(start)
            return String(format: "%.1fs（进行中）", duration)
        }
    }

    private func shortRunId(_ runId: String) -> String {
        if runId.count <= 10 {
            return runId
        }
        return "\(runId.prefix(6))…\(runId.suffix(4))"
    }
}

// MARK: - Tool Detail Section

struct ToolDetailSection: View {
    let title: String
    let content: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(color)
            }

            Text(content)
                .font(.system(size: 13))
                .foregroundColor(.primary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
        }
    }
}

struct ToolExecutionGroupCard: View {
    let tools: [ToolExecution]
    @State private var isExpanded: Bool

    init(tools: [ToolExecution]) {
        self.tools = tools.sorted { $0.startTime < $1.startTime }
        let hasRunning = tools.contains { $0.status == .running }
        _isExpanded = State(initialValue: hasRunning)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.orange)

                    Text("工具执行")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.primary)

                    Text("\(tools.count)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemGray5))
                        .clipShape(Capsule())

                    Spacer()

                    Text(summaryText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(summaryColor)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(.systemGray4), lineWidth: 1)
                )
                .cornerRadius(10)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 8) {
                    ForEach(tools) { tool in
                        ToolExecutionView(tool: tool)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var summaryText: String {
        let running = tools.filter { $0.status == .running }.count
        let failed = tools.filter { $0.status == .failed }.count
        if running > 0 {
            return "进行中 \(running)"
        }
        if failed > 0 {
            return "失败 \(failed)"
        }
        return "已完成"
    }

    private var summaryColor: Color {
        let running = tools.contains { $0.status == .running }
        let failed = tools.contains { $0.status == .failed }
        if running { return .blue }
        if failed { return .red }
        return .green
    }
}

// MARK: - Preview

struct ToolExecutionView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            // Running tool
            ToolExecutionView(tool: ToolExecution(
                id: "1",
                runId: nil,
                name: "Read",
                phase: .start,
                input: "/path/to/file.txt",
                output: nil,
                error: nil,
                startTime: Date(),
                endTime: nil
            ))

            // Completed tool
            ToolExecutionView(tool: ToolExecution(
                id: "2",
                runId: nil,
                name: "Bash",
                phase: .result,
                input: "ls -la",
                output: "total 42\ndrwxr-xr-x  5 user  staff  160 Jan  1 12:00 .\ndrwxr-xr-x  3 user  staff   96 Jan  1 12:00 ..",
                error: nil,
                startTime: Date().addingTimeInterval(-2.5),
                endTime: Date()
            ))

            // Failed tool
            ToolExecutionView(tool: ToolExecution(
                id: "3",
                runId: nil,
                name: "Write",
                phase: .result,
                input: "/invalid/path/file.txt",
                output: nil,
                error: "Permission denied: cannot write to /invalid/path",
                startTime: Date().addingTimeInterval(-1.0),
                endTime: Date()
            ))
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
