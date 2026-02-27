//
//  ChatToolbar.swift
//  contextgo
//
//  Toolbar above input bar with recording button
//  Automatically hides during recording state
//  Updated: Uses shared DerivedData with Xcode
//

import SwiftUI
import UIKit

struct ChatToolbar: View {
    @Binding var recordingState: RecordingState
    let onShowSkills: (() -> Void)?
    let onShowUsageStats: (() -> Void)?
    let onShowCronJobs: (() -> Void)?
    let onShowSettings: (() -> Void)?
    let onShowThinking: (() -> Void)?  // 思考等级控制
    var thinkingLabel: String? = nil

    var showLeftPadding: Bool = true  // 是否显示左边距（当没有ContextGO指示器时需要）

    var isEnabled: Bool {
        recordingState == .idle
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                // ✅ NEW: Skills button (if callback is provided)
                if let onShowSkills = onShowSkills {
                    ToolbarButton(
                        icon: "puzzlepiece.fill",  // 使用兼容性更好的图标
                        label: "技能",
                        action: onShowSkills
                    )
                    .disabled(!isEnabled)
                }

                // ✅ NEW: Usage statistics button
                if let onShowUsageStats = onShowUsageStats {
                    ToolbarButton(
                        icon: "chart.bar.fill",
                        label: "Token",
                        action: onShowUsageStats
                    )
                    .disabled(!isEnabled)
                }

                // ✅ NEW: Cron jobs button
                if let onShowCronJobs = onShowCronJobs {
                    ToolbarButton(
                        icon: "clock.fill",
                        label: "定时任务",
                        action: onShowCronJobs
                    )
                    .disabled(!isEnabled)
                }

                // ✅ NEW: Settings button
                if let onShowSettings = onShowSettings {
                    ToolbarButton(
                        icon: "gearshape.fill",
                        label: "设置",
                        action: onShowSettings
                    )
                    .disabled(!isEnabled)
                }

                // 思考等级按钮
                if let onShowThinking = onShowThinking {
                    ToolbarButton(
                        icon: "brain",
                        label: thinkingLabel ?? "思考",
                        action: onShowThinking
                    )
                    .disabled(!isEnabled)
                }
            }
            .padding(.leading, showLeftPadding ? 16 : 0)
            .padding(.trailing, 16)
        }
        .padding(.vertical, 6)
        .opacity(isEnabled ? 1.0 : 0.0)
        .offset(y: isEnabled ? 0 : -10)
        .animation(.easeInOut(duration: 0.25), value: isEnabled)
    }
}

// MARK: - Toolbar Button
struct ToolbarButton: View {
    let icon: String
    let label: String?
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    init(icon: String, label: String? = nil, action: @escaping () -> Void) {
        self.icon = icon
        self.label = label
        self.action = action
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(isEnabled ? (colorScheme == .dark ? .cyan : .blue) : .gray)

                if let label = label {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(isEnabled ? (colorScheme == .dark ? .white : .blue) : .gray)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(
                        isEnabled
                        ? (colorScheme == .dark ? Color(uiColor: UIColor.secondarySystemBackground) : .white)
                        : (colorScheme == .dark ? Color(uiColor: UIColor.systemGray5) : Color(uiColor: UIColor.systemGray6))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isEnabled
                        ? (colorScheme == .dark ? Color.cyan.opacity(0.35) : Color.blue.opacity(0.25))
                        : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.08)),
                        lineWidth: isEnabled ? 1 : 0.5
                    )
            )
            .shadow(
                color: isEnabled
                    ? (colorScheme == .dark ? Color.cyan.opacity(0.12) : Color.blue.opacity(0.1))
                    : .clear,
                radius: 3,
                x: 0,
                y: 1
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 20) {
        // Enabled state
        ChatToolbar(
            recordingState: .constant(.idle),
            onShowSkills: { print("Show skills") },
            onShowUsageStats: { print("Show usage stats") },
            onShowCronJobs: { print("Show cron jobs") },
            onShowSettings: { print("Show settings") },
            onShowThinking: { print("Show thinking") },
            thinkingLabel: "思考·中"
        )

        Divider()

        // Disabled state (recording)
        ChatToolbar(
            recordingState: .constant(.recording),
            onShowSkills: { print("Show skills") },
            onShowUsageStats: { print("Show usage stats") },
            onShowCronJobs: { print("Show cron jobs") },
            onShowSettings: { print("Show settings") },
            onShowThinking: { print("Show thinking") },
            thinkingLabel: "思考·中"
        )
    }
    .padding()
}
