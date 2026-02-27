//
//  ChatMessageBubble.swift
//  contextgo
//
//  Extracted message bubble rendering for ChatView
//

import SwiftUI
import UIKit

struct MessageBubble: View {
    let message: ChatMessage
    @State private var didCopyUserText = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.isUser {
                Spacer(minLength: 0)
            }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 8) {
                if message.isStreaming && message.text.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(0..<3) { index in
                            Circle()
                                .fill(Color(.systemGray3))
                                .frame(width: 8, height: 8)
                                .scaleEffect(1.0)
                                .animation(
                                    Animation
                                        .easeInOut(duration: 0.6)
                                        .repeatForever()
                                        .delay(Double(index) * 0.2),
                                    value: message.isStreaming
                                )
                        }
                    }
                    .padding(12)
                } else {
                    if message.isAudioMessage {
                        userCopyWrapped(
                            HStack(spacing: 8) {
                                Image(systemName: "waveform")
                                    .font(.system(size: 16))
                                    .foregroundColor(message.isUser ? Color(.systemGray) : .blue)

                                Text(message.text)
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .padding(12)
                            .background(message.isUser ? Color(.systemGray5) : Color.clear)
                            .foregroundColor(message.isUser ? Color(.label) : .primary)
                            .cornerRadius(message.isUser ? 16 : 0)
                        )
                    } else {
                        if !message.isUser,
                           let thinking = ChatMessageContentParser.extractThinkingContent(from: message.text) {
                            VStack(alignment: .leading, spacing: 8) {
                                DisclosureGroup {
                                    MarkdownText(markdown: thinking, isUserMessage: false)
                                        .padding(10)
                                        .background(Color(.systemGray6))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(Color(.systemGray4), lineWidth: 1)
                                        )
                                        .cornerRadius(10)
                                        .padding(.top, 4)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "brain.head.profile")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.secondary)
                                        Text("思考过程")
                                            .font(.caption)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.primary)
                                        Text("点击展开")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 7)
                                    .background(Color(.systemGray6))
                                    .overlay(
                                        Capsule()
                                            .stroke(Color(.systemGray4), lineWidth: 1)
                                    )
                                    .clipShape(Capsule())
                                }
                                .tint(.secondary)

                                if let mainText = ChatMessageContentParser.removeThinkingContent(from: message.text),
                                   !mainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    renderMessageContent(mainText, isUserMessage: false)
                                }
                            }
                        } else {
                            userCopyWrapped(
                                renderMessageContent(message.text, isUserMessage: message.isUser)
                                    .padding(message.isUser ? 12 : 0)
                                    .background(message.isUser ? Color(.systemGray5) : Color.clear)
                                    .foregroundColor(message.isUser ? Color(.label) : .primary)
                                    .cornerRadius(message.isUser ? 16 : 0)
                            )
                        }
                    }
                }

                if let tools = message.toolExecutions, !tools.isEmpty {
                    ToolExecutionGroupCard(tools: tools)
                }

                if message.isStreaming {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("正在输入...")
                            .font(.caption2)
                            .foregroundColor(.gray)
                    }
                } else {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
            }
            .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)

            if !message.isUser {
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func userCopyWrapped<Content: View>(_ content: Content) -> some View {
        if message.isUser {
            content
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .contextMenu {
                    Button {
                        copyUserMessageText()
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if didCopyUserText {
                        Text("已复制")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.green)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(.systemBackground))
                            .clipShape(Capsule())
                            .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                            .offset(x: 2, y: -6)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
        } else {
            content
        }
    }

    private func copyUserMessageText() {
        let payload = message.text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        UIPasteboard.general.string = payload
        let feedback = UINotificationFeedbackGenerator()
        feedback.notificationOccurred(.success)

        withAnimation(.easeInOut(duration: 0.15)) {
            didCopyUserText = true
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            withAnimation(.easeInOut(duration: 0.15)) {
                didCopyUserText = false
            }
        }
    }

    @ViewBuilder
    private func renderMessageContent(_ text: String, isUserMessage: Bool) -> some View {
        let segments = ChatMessageContentParser.parseSegments(from: text, isUserMessage: isUserMessage)

        if segments.count == 1,
           case let .markdown(markdown) = segments[0] {
            MarkdownText(markdown: markdown, isUserMessage: isUserMessage)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .markdown(let markdown):
                        MarkdownText(markdown: markdown, isUserMessage: isUserMessage)
                    case .media(let url):
                        MediaLinkCard(url: url)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
