//
//  ChatInputBar.swift
//  contextgo
//
//  Modern input bar with Claude Code style interaction
//  Two-line card layout with smooth animations
//

import SwiftUI

struct ChatInputBar: View {
    @Environment(\.colorScheme) private var colorScheme

    // Input text
    @Binding var inputText: String
    @FocusState.Binding var isInputFocused: Bool

    // Input mode and recording state
    @Binding var inputMode: InputMode
    @Binding var recordingState: RecordingState
    @Binding var recordingDuration: TimeInterval

    // Real-time ASR
    @Binding var recognizedText: String
    @Binding var partialText: String

    // Connection state
    var isConnected: Bool = true

    // Recognition state
    var isRecognizing: Bool = false
    var isMeetingRecording: Bool = false
    @Binding var meetingPhase: MeetingRecordingPhase

    // Surface styling
    var containerBackground: Color = Color(.systemGroupedBackground)
    var highlightLeadingSkillToken: Bool = false
    var selectedSkillName: String? = nil
    var onClearSelectedSkill: (() -> Void)? = nil

    // Attachments
    @Binding var selectedAttachments: [AttachmentItem]
    @Binding var showAttachmentPicker: Bool

    // Stop/settings/attachment capability bundle
    var accessory: ChatComposerAccessory? = nil
    // Legacy fields (kept for compatibility during migration)
    var hasActiveRuns: Bool = false
    var isStoppingRun: Bool = false
    var onStopRun: (() -> Void)?
    var showAttachmentButton: Bool = true
    var onOpenSettings: (() -> Void)? = nil

    // Callbacks
    let onSend: () -> Void
    let onCancelRecording: () -> Void
    let onSendRecording: () -> Void
    let onHoldStartRecording: () -> Void
    let onHoldSendRecording: () -> Void
    let onStartMeetingRecording: () -> Void
    let onPauseMeetingRecording: () -> Void
    let onResumeMeetingRecording: () -> Void
    let onMeetingRecording: (() -> Void)?
    var onDismissMeetingRecording: (() -> Void)? = nil

    // State
    @Binding var isHoldingSpeakButton: Bool
    @Namespace private var composerMorphNamespace

    private var isHoldToSpeakCardVisible: Bool {
        isHoldingSpeakButton || isRecognizing
    }

    private var effectiveHasActiveRuns: Bool {
        accessory?.hasActiveRuns ?? hasActiveRuns
    }

    private var effectiveIsStoppingRun: Bool {
        accessory?.isStoppingRun ?? isStoppingRun
    }

    private var effectiveShowAttachmentButton: Bool {
        accessory?.showsAttachmentButton ?? showAttachmentButton
    }

    private var effectiveOnStopRun: (() -> Void)? {
        accessory?.onStopRun ?? onStopRun
    }

    private var effectiveOnOpenSettings: (() -> Void)? {
        accessory?.onOpenSettings ?? onOpenSettings
    }

    private var composerMorphAnimation: Animation {
        .spring(response: 0.42, dampingFraction: 0.86, blendDuration: 0.12)
    }

    private var decorativeAnimation: Animation? {
        UIRenderPerformance.allowsDecorativeAnimation ? composerMorphAnimation : nil
    }

    private var quickSpringAnimation: Animation? {
        UIRenderPerformance.allowsDecorativeAnimation ? .spring(response: 0.3, dampingFraction: 0.7) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Attachments preview
            if !selectedAttachments.isEmpty {
                attachmentsPreview
            }

            if isMeetingRecording {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 1)
            }
            // Recording state (hold-to-speak)
            else if isHoldingSpeakButton || isRecognizing {
                recordingCard
            }
            // Normal input card
            else {
                inputCard
            }
        }
        .background(containerBackground)
        .frame(maxWidth: .infinity, alignment: .bottom)
        .overlay(alignment: .bottom) {
            if isMeetingRecording {
                meetingRecordingCard
                    .zIndex(1)
            }
        }
        .sheet(isPresented: $showAttachmentPicker) {
            attachmentPickerSheet
        }
        .animation(decorativeAnimation, value: isHoldToSpeakCardVisible)
        .animation(decorativeAnimation, value: isMeetingRecording)
    }

    // MARK: - Subviews

    /// Attachments preview section
    @ViewBuilder
    private var attachmentsPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(selectedAttachments) { attachment in
                    AttachmentCard(attachment: attachment) {
                        withAnimation(quickSpringAnimation) {
                            selectedAttachments.removeAll { $0.id == attachment.id }
                            triggerHaptic(style: .light)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .frame(height: 90)
        .transition(UIRenderPerformance.allowsDecorativeAnimation ? .move(edge: .bottom).combined(with: .opacity) : .identity)
    }

    /// Main input card with always-visible button row
    @ViewBuilder
    private var inputCard: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                TextField(
                    "输入消息...",
                    text: $inputText,
                    axis: .vertical
                )
                .font(.system(size: 17))
                .lineLimit(1...4)
                .focused($isInputFocused)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 4)
                .frame(minHeight: 40, alignment: .topLeading)
            }

            // Bottom: Button row (always visible)
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    if let skillName = highlightedSkillName {
                        selectedSkillBadge(skillName: skillName)
                            .frame(maxWidth: 160, alignment: .leading)
                            .transition(UIRenderPerformance.allowsDecorativeAnimation ? .move(edge: .leading).combined(with: .opacity) : .identity)
                    }

                    // Left: Attachment picker button
                    if effectiveShowAttachmentButton {
                        Button(action: {
                            triggerHaptic(style: .light)
                            isInputFocused = false
                            showAttachmentPicker = true
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.1))
                                    .frame(width: 32, height: 32)

                                Image(systemName: "plus")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    // Optional: inline settings button (used by CLI relay chat)
                    if let onOpenSettings = effectiveOnOpenSettings {
                        Button(action: {
                            triggerHaptic(style: .light)
                            isInputFocused = false
                            onOpenSettings()
                        }) {
                            ZStack {
                                Circle()
                                    .fill(Color.gray.opacity(0.12))
                                    .frame(width: 32, height: 32)

                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Spacer()

                // Right: Stop button (if has active runs)
                if effectiveHasActiveRuns {
                    Button(action: {
                        triggerHaptic(style: .medium)
                        effectiveOnStopRun?()
                    }) {
                        HStack(spacing: 4) {
                            if effectiveIsStoppingRun {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                                Text("停止中…")
                                    .font(.system(size: 13, weight: .medium))
                            } else {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("停止")
                                    .font(.system(size: 13, weight: .medium))
                            }
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(effectiveIsStoppingRun ? Color.orange : Color.red)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(effectiveIsStoppingRun)
                    .transition(UIRenderPerformance.allowsDecorativeAnimation ? .scale.combined(with: .opacity) : .identity)
                }

                // Right: Send button (when has text) or Record button
                if !inputText.isEmpty || !selectedAttachments.isEmpty {
                    Button(action: {
                        triggerHaptic(style: .medium)
                        onSend()
                    }) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 32))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .transition(UIRenderPerformance.allowsDecorativeAnimation ? .scale.combined(with: .opacity) : .identity)
                } else {
                    Button(action: {
                        if isConnected {
                            triggerHaptic(style: .medium)
                            onHoldStartRecording()
                        }
                    }) {
                        ZStack {
                            Circle()
                                .fill(isConnected ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1))
                                .frame(width: 38, height: 38)

                            Image(systemName: "mic.fill")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundColor(isConnected ? .blue : .gray.opacity(0.5))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!isConnected)
                    .transition(UIRenderPerformance.allowsDecorativeAnimation ? .scale.combined(with: .opacity) : .identity)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .padding(.top, 4)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground))
                .overlay {
                    if UIRenderPerformance.highPerformanceModeEnabled {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(Color.black.opacity(0.08), lineWidth: 0.5)
                    }
                }
                .modifier(ComposerMorphModifier(enabled: UIRenderPerformance.allowsDecorativeAnimation, namespace: composerMorphNamespace))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    isInputFocused
                        ? Color.blue.opacity(0.36)
                        : Color(uiColor: .separator).opacity(colorScheme == .dark ? 0.42 : 0.24),
                    lineWidth: isInputFocused ? 1.5 : 1
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 2)
        .shadow(
            color: UIRenderPerformance.highPerformanceModeEnabled
                ? .clear
                : Color.black.opacity(colorScheme == .dark ? 0.22 : 0.1),
            radius: UIRenderPerformance.highPerformanceModeEnabled ? 0 : 12,
            x: 0,
            y: UIRenderPerformance.highPerformanceModeEnabled ? 0 : 4
        )
        .animation(quickSpringAnimation, value: inputText.isEmpty)
        .animation(quickSpringAnimation, value: isInputFocused)
        .animation(quickSpringAnimation, value: effectiveHasActiveRuns)
        .animation(quickSpringAnimation, value: effectiveIsStoppingRun)
        .transition(UIRenderPerformance.allowsDecorativeAnimation ? .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.995)),
            removal: .opacity.combined(with: .scale(scale: 0.995))
        ) : .identity)
    }

    /// Recording card (single-line with waveform)
    @ViewBuilder
    private var recordingCard: some View {
        HStack(spacing: 16) {
            // Left: Cancel button
            Button(action: {
                triggerHaptic(style: .medium)
                if !isRecognizing {
                    onCancelRecording()
                }
            }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(isRecognizing ? .gray.opacity(0.3) : .red)
            }
            .buttonStyle(.plain)
            .disabled(isRecognizing)

            // Center: Waveform + Timer
            VStack(spacing: 4) {
                if isRecognizing {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform.badge.magnifyingglass")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text("识别中...")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                } else {
                    // Audio waveform animation
                    HStack(spacing: 3) {
                        ForEach(0..<(UIRenderPerformance.highPerformanceModeEnabled ? 8 : 15), id: \.self) { index in
                            WaveformBar(
                                index: index,
                                useHighPerformanceStyle: UIRenderPerformance.highPerformanceModeEnabled
                            )
                        }
                    }

                    // Timer
                    Text(formatTime(recordingDuration))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundColor(.blue)
                }
            }
            .frame(maxWidth: .infinity)

            // Right: Send button
            Button(action: {
                triggerHaptic(style: .medium)
                onHoldSendRecording()
            }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundColor(isRecognizing ? .gray.opacity(0.5) : .blue)
            }
            .buttonStyle(.plain)
            .disabled(isRecognizing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.systemBackground))
                .modifier(ComposerMorphModifier(enabled: UIRenderPerformance.allowsDecorativeAnimation, namespace: composerMorphNamespace))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1.5)
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .shadow(
            color: UIRenderPerformance.highPerformanceModeEnabled ? .clear : Color.blue.opacity(0.1),
            radius: UIRenderPerformance.highPerformanceModeEnabled ? 0 : 12,
            x: 0,
            y: UIRenderPerformance.highPerformanceModeEnabled ? 0 : 4
        )
        .transition(UIRenderPerformance.allowsDecorativeAnimation ? .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.985)),
            removal: .opacity.combined(with: .scale(scale: 0.985))
        ) : .identity)
        .animation(quickSpringAnimation, value: isRecognizing)
    }

    /// Meeting recording card
    @ViewBuilder
    private var meetingRecordingCard: some View {
        MeetingRecordingView(
            phase: $meetingPhase,
            duration: $recordingDuration,
            onStart: onStartMeetingRecording,
            onPause: onPauseMeetingRecording,
            onResume: onResumeMeetingRecording,
            onFinish: onSendRecording,
            onCancel: onCancelRecording,
            onDismiss: onDismissMeetingRecording
        )
        .frame(maxWidth: .infinity, alignment: .bottom)
        .transition(UIRenderPerformance.allowsDecorativeAnimation ? .move(edge: .bottom).combined(with: .opacity) : .identity)
    }

    /// Attachment picker sheet
    @ViewBuilder
    private var attachmentPickerSheet: some View {
        AttachmentPickerPanel(
            selectedAttachments: $selectedAttachments,
            onDismiss: {
                showAttachmentPicker = false
            },
            onMeetingRecording: onMeetingRecording
        )
        .padding(.horizontal, 10)
        .presentationDetents([.height(200)])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Helper Methods

    private func triggerHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let impact = UIImpactFeedbackGenerator(style: style)
        impact.impactOccurred()
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private var highlightedSkillName: String? {
        if let explicitSelectedSkillName = selectedSkillName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicitSelectedSkillName.isEmpty {
            return explicitSelectedSkillName
        }

        guard highlightLeadingSkillToken else { return nil }
        let text = inputText
        guard text.hasPrefix("$") else { return nil }

        var token = ""
        for char in text {
            if char.isWhitespace || char.isNewline {
                break
            }
            token.append(char)
        }

        guard token.count > 1 else { return nil }
        return token.hasPrefix("$") ? String(token.dropFirst()) : token
    }

    @ViewBuilder
    private func selectedSkillBadge(skillName: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.green)
            Text(skillName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.green.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.tail)
            if let onClearSelectedSkill {
                Button {
                    triggerHaptic(style: .light)
                    onClearSelectedSkill()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.green.opacity(0.8))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(Color.green.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.green.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("已选择技能 \(skillName)")
    }
}

// MARK: - Waveform Bar Component

struct WaveformBar: View {
    let index: Int
    let useHighPerformanceStyle: Bool
    @State private var amplitude: CGFloat = 0.3

    var body: some View {
        Group {
            if useHighPerformanceStyle {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.blue)
                    .frame(width: 2.5, height: 22 * amplitude)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(
                        LinearGradient(
                            colors: [Color.blue, Color.cyan],
                            startPoint: .bottom,
                            endPoint: .top
                        )
                    )
                    .frame(width: 3, height: 22 * amplitude)
            }
        }
        .animation(
            Animation.easeInOut(duration: useHighPerformanceStyle ? 0.7 : 0.5)
                .repeatForever(autoreverses: true)
                .delay(Double(index) * 0.05),
            value: amplitude
        )
        .onAppear {
            amplitude = CGFloat.random(in: 0.3...1.0)
        }
    }
}

private struct ComposerMorphModifier: ViewModifier {
    let enabled: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if enabled {
            content.matchedGeometryEffect(id: "composer.surface", in: namespace)
        } else {
            content
        }
    }
}

// MARK: - Preview

#Preview {
    VStack {
        Spacer()

        ChatInputBar(
            inputText: .constant(""),
            isInputFocused: FocusState<Bool>().projectedValue,
            inputMode: .constant(.text),
            recordingState: .constant(.idle),
            recordingDuration: .constant(0),
            recognizedText: .constant(""),
            partialText: .constant(""),
            isConnected: true,
            meetingPhase: .constant(.ready),
            selectedAttachments: .constant([]),
            showAttachmentPicker: .constant(false),
            hasActiveRuns: false,
            onStopRun: { print("Stop run") },
            showAttachmentButton: true,
            onOpenSettings: { print("Open settings") },
            onSend: { print("Send") },
            onCancelRecording: { print("Cancel recording") },
            onSendRecording: { print("Send recording") },
            onHoldStartRecording: { print("Hold start recording") },
            onHoldSendRecording: { print("Hold send recording") },
            onStartMeetingRecording: { print("Start meeting recording") },
            onPauseMeetingRecording: { print("Pause meeting recording") },
            onResumeMeetingRecording: { print("Resume meeting recording") },
            onMeetingRecording: { print("Meeting recording from attachment") },
            isHoldingSpeakButton: .constant(false)
        )
    }
    .background(Color(.systemBackground))
}
