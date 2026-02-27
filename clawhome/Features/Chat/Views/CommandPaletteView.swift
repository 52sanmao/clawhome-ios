//
//  CommandPaletteView.swift
//  contextgo
//
//  Command palette for slash commands
//

import SwiftUI

struct CommandPaletteView: View {
    let commands: [SlashCommand]
    let onSelect: (SlashCommand) -> Void

    @Environment(\.colorScheme) private var colorScheme

    // ✅ 最大高度设置
    private let maxHeight: CGFloat = 300

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if commands.isEmpty {
                    // 空状态
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                        Text("没有找到匹配的命令")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 16)
                } else {
                    // 命令列表
                    ForEach(commands) { command in
                        CommandRow(command: command)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(command)
                            }

                        if command.id != commands.last?.id {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: maxHeight)  // ✅ 限制最大高度
        .background(paletteBackground)
        .cornerRadius(12)
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.15),
            radius: 12,
            x: 0,
            y: 4
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(borderColor, lineWidth: 1)
        )
    }

    private var paletteBackground: Color {
        colorScheme == .dark
            ? Color(white: 0.15)
            : Color.white
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color(white: 0.3)
            : Color(white: 0.9)
    }
}

struct CommandRow: View {
    let command: SlashCommand

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            ZStack {
                Circle()
                    .fill(iconBackground)
                    .frame(width: 32, height: 32)

                Image(systemName: command.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(iconForeground)
            }

            // Text
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("/")
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text(command.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                }

                Text(command.description)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Enter hint
            HStack(spacing: 4) {
                Image(systemName: "return")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.secondary.opacity(0.6))
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(4)
        }
        .padding(.vertical, 12)  // ✅ 增加垂直内边距
        .padding(.horizontal, 14)  // ✅ 优化水平内边距
        .background(isHovering ? hoverBackground : Color.clear)
    }

    private var iconBackground: Color {
        switch command.category {
        case .session:
            switch command.action {
            case .local(.clearSession):
                return Color.red.opacity(0.15)
            case .sendToAI:
                return Color.orange.opacity(0.15)
            }
        case .status:
            return Color.green.opacity(0.15)
        case .model:
            return Color.purple.opacity(0.15)
        case .tools:
            return Color.indigo.opacity(0.15)
        case .channel:
            return Color.cyan.opacity(0.15)
        }
    }

    private var iconForeground: Color {
        switch command.category {
        case .session:
            switch command.action {
            case .local(.clearSession):
                return .red
            case .sendToAI:
                return .orange
            }
        case .status:
            return .green
        case .model:
            return .purple
        case .tools:
            return .indigo
        case .channel:
            return .cyan
        }
    }

    private var hoverBackground: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.04)
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()

        CommandPaletteView(
            commands: SlashCommand.allCommands,
            onSelect: { command in
                print("Selected: \(command.name)")
            }
        )
        .padding(.horizontal, 16)
        .frame(maxWidth: 400)

        Spacer()
    }
    .preferredColorScheme(.dark)
}
