//
//  HoldToSpeakIndicator.swift
//  contextgo
//
//  Recording indicator shown when holding the speak button
//

import SwiftUI

struct HoldToSpeakIndicator: View {
    @Binding var recordingDuration: TimeInterval
    @Binding var recognizedText: String      // 已识别的完整文字
    @Binding var partialText: String         // 部分识别结果
    var isRecognizing: Bool = false          // ✅ 是否正在识别（录音已停止）
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 12) {
            // Top: Recording/Recognizing status
            HStack(spacing: 16) {
                // Left: Status animation
                HStack(spacing: 12) {
                    Circle()
                        .fill(isRecognizing ? Color.blue : Color.red)
                        .frame(width: 12, height: 12)
                        .scaleEffect(pulseScale)
                        .onAppear {
                            withAnimation(
                                Animation.easeInOut(duration: 1.0).repeatForever(autoreverses: true)
                            ) {
                                pulseScale = 1.5
                            }
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(isRecognizing ? "识别中" : "正在录音")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.primary)

                        if !isRecognizing {
                            Text(formatTime(recordingDuration))
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
                                .foregroundColor(.blue)
                        } else {
                            Text("请稍候...")
                                .font(.system(size: 14))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                // Right: Release hint (only show when recording)
                if !isRecognizing {
                    HStack(spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .font(.system(size: 18))
                            .foregroundColor(.blue)

                        Text("松开发送")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.blue)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.blue.opacity(0.1))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1.5)
                    )
                }
            }

            // Bottom: Real-time transcript - 仅在识别中显示
            if isRecognizing {
                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "waveform")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Text(recognizedText.isEmpty && partialText.isEmpty ? "说点什么..." : "识别结果")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.secondary)
                        Spacer()
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            // Show recognized text (final)
                            if !recognizedText.isEmpty {
                                Text(recognizedText)
                                    .font(.system(size: 16, weight: .medium))
                                    .foregroundColor(.primary)
                            }

                            // Show partial text (interim)
                            if !partialText.isEmpty {
                                Text(partialText)
                                    .font(.system(size: 16))
                                    .foregroundColor(.secondary)
                                    .italic()
                            }

                            // Placeholder when no text
                            if recognizedText.isEmpty && partialText.isEmpty {
                                Text("等待语音输入...")
                                    .font(.system(size: 15))
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .italic()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: Color.black.opacity(0.1), radius: 8, x: 0, y: -2)
        )
        .padding(.horizontal, 16)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    VStack {
        Spacer()

        HoldToSpeakIndicator(
            recordingDuration: .constant(5.5),
            recognizedText: .constant("你好，这是一段测试文字。"),
            partialText: .constant("正在识别中...")
        )
    }
    .background(Color(.systemGray6))
}
