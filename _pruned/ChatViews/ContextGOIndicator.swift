//
//  ContextGOIndicator.swift
//  contextgo
//
//  ContextGO status indicator with button-like style (non-interactive)
//

import SwiftUI

struct ContextGOIndicator: View {
    let isEnabled: Bool
    @Binding var recordingState: RecordingState

    var isVisible: Bool {
        // Only show when ContextGO is enabled AND not recording
        isEnabled && recordingState == .idle
    }

    var body: some View {
        if isVisible {
            HStack {
                Spacer()

                HStack(spacing: 8) {
                    // Brain icon
                    Image(systemName: "brain.head.profile")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .foregroundColor(.purple)

                    // Status text
                    Text("AI 已链接智慧大脑")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)

                    // Breathing dot indicator
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.green, Color.cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 6, height: 6)
                        .scaleEffect(isEnabled ? 1.2 : 1.0)
                        .opacity(isEnabled ? 0.8 : 0.5)
                        .animation(
                            isEnabled
                                ? Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                                : .default,
                            value: isEnabled
                        )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.green.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.green.opacity(0.2), lineWidth: 1)
                )

                Spacer()
            }
            .padding(.vertical, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 20) {
        // Enabled state
        ContextGOIndicator(
            isEnabled: true,
            recordingState: .constant(.idle)
        )

        // Disabled state
        ContextGOIndicator(
            isEnabled: false,
            recordingState: .constant(.idle)
        )

        // Hidden (recording)
        ContextGOIndicator(
            isEnabled: true,
            recordingState: .constant(.recordingUnlocked)
        )
    }
    .padding()
}
