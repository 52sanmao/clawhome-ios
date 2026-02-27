//
//  MeetingRecordingView.swift
//  contextgo
//
//  Meeting recording UI with start, pause/resume, and finish controls
//

import SwiftUI

enum MeetingRecordingPhase {
    case ready      // 等待开始
    case recording  // 录音中
    case paused     // 已暂停
}

struct MeetingRecordingView: View {
    @Binding var phase: MeetingRecordingPhase
    @Binding var duration: TimeInterval

    let onStart: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onFinish: () -> Void
    let onCancel: () -> Void
    var onDismiss: (() -> Void)? = nil  // 返回键盘输入模式

    var body: some View {
        HStack(spacing: 16) {
            // Left: Back button (only in ready phase) + Timer with status indicator
            HStack(spacing: 12) {
                // Back button - only show when not yet started
                if phase == .ready, let onDismiss = onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Color(.systemGray5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }

                // Status indicator
                if phase != .ready {
                    Circle()
                        .fill(phase == .recording ? Color.red : Color.orange)
                        .frame(width: 10, height: 10)
                        .scaleEffect(phase == .recording ? 1.2 : 1.0)
                        .animation(
                            phase == .recording
                                ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                                : .default,
                            value: phase
                        )
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(phase == .ready ? "录音纪要" : "会议录音")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)

                    if phase != .ready {
                        Text(formatTime(duration))
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("长按录制会议内容")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer(minLength: 0)

            // Right: Control buttons
            HStack(spacing: 10) {
                if phase == .ready {
                    Button(action: onStart) {
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 16, weight: .semibold))
                            Text("开始")
                                .font(.system(size: 15, weight: .semibold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.red)
                        .cornerRadius(20)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: phase == .paused ? onResume : onPause) {
                        Image(systemName: phase == .paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.orange)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Button(action: onFinish) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.green)
                    }
                    .buttonStyle(.plain)

                    Button(action: onCancel) {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark")
                            Text("取消")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.06), radius: 8, x: 0, y: 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

// MARK: - Preview
#Preview {
    VStack(spacing: 40) {
        // Ready state
        MeetingRecordingView(
            phase: .constant(.ready),
            duration: .constant(0),
            onStart: { print("Start") },
            onPause: { print("Pause") },
            onResume: { print("Resume") },
            onFinish: { print("Finish") },
            onCancel: { print("Cancel") }
        )

        // Recording state
        MeetingRecordingView(
            phase: .constant(.recording),
            duration: .constant(45.5),
            onStart: { print("Start") },
            onPause: { print("Pause") },
            onResume: { print("Resume") },
            onFinish: { print("Finish") },
            onCancel: { print("Cancel") }
        )

        // Paused state
        MeetingRecordingView(
            phase: .constant(.paused),
            duration: .constant(128.3),
            onStart: { print("Start") },
            onPause: { print("Pause") },
            onResume: { print("Resume") },
            onFinish: { print("Finish") },
            onCancel: { print("Cancel") }
        )

        Spacer()
    }
    .background(Color(.systemBackground))
}
