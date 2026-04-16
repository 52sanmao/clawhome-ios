//
//  ChatView.swift
//  contextgo
//
//  Chat interface backed by IronClaw
//

import SwiftUI
import UIKit

struct ChatView: View {
    @StateObject private var viewModel: ChatViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var isInputFocused: Bool

    // ✅ NEW: Attachment state
    @State private var selectedAttachments: [AttachmentItem] = []
    @State private var showAttachmentPicker = false

    // ✅ NEW: Skills list state
    @State private var showSkillsSheet = false

    // ✅ NEW: Usage statistics state
    @State private var showUsageStatistics = false

    // ✅ NEW: Cron jobs state
    @State private var showCronJobs = false

    // ✅ NEW: Settings state (model configuration)
    @State private var showSettings = false

    @State private var showTitleRenameSheet = false
    @State private var pendingTitleInput = ""
    @State private var customSessionTitle: String?

    // 思考等级控制 state
    @State private var showThinkingLevel = false
    @State private var isBottomAnchorVisible = true
    @State private var bottomAnchorMaxY: CGFloat = 0
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var lastAutoScrollTimestamp: CFAbsoluteTime = 0

    private let messagesScrollSpaceName = "chat-messages-scroll-space"
    private let bottomScrollAnchorId = "chat-scroll-bottom-anchor"
    private let autoScrollThrottleInterval: CFAbsoluteTime = 0.12
    private let sessionTitle: String?
    private let sessionRepository = LocalSessionRepository.shared

    var onDismiss: (() -> Void)?  // Optional dismiss callback

    init(
        agent: CloudAgent? = nil,
        sessionId: String? = nil,
        sessionKey: String? = nil,
        sessionTitle: String? = nil,
        onDismiss: (() -> Void)? = nil
    ) {
        _viewModel = StateObject(wrappedValue: ChatViewModel(
            agent: agent,
            sessionId: sessionId,
            sessionKey: sessionKey
        ))
        let normalizedTitle = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        _customSessionTitle = State(initialValue: (normalizedTitle?.isEmpty == false) ? normalizedTitle : nil)
        self.sessionTitle = sessionTitle
        self.onDismiss = onDismiss
    }

    var body: some View {
        ChatScreenShell(
            topBanner: { otherChannelBannerView },
            timeline: { messagesScrollView },
            inputHeader: { inputHeaderSectionView },
            composer: { inputSectionView }
        )
        .overlay {
            // Status bar blur overlay
            VStack {
                statusBarBlur
                Spacer()
            }
            .ignoresSafeArea()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            navigationLeadingItem
            navigationTitleItem
        }
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "未知错误")
        }
        .onDisappear {
            if viewModel.isHoldingSpeakButton {
                print("⚠️ [ChatView] onDisappear - 检测到录音未停止，强制停止")
                Task { await viewModel.finishHoldToSpeakRecording() }
            }
            viewModel.cleanup()
        }
        .sheet(isPresented: $viewModel.showFilePicker) {
            FilePicker(isPresented: $viewModel.showFilePicker) { url in
                viewModel.handleFileSelected(url)
            }
        }
        .sheet(isPresented: $viewModel.showImagePicker) {
            ImagePicker(isPresented: $viewModel.showImagePicker) { image in
                viewModel.handleImageSelected(image)
            }
        }
        .confirmationDialog("更多选项", isPresented: $viewModel.showMoreOptions) {
            Button("📍 位置") { print("位置") }
            Button("📋 收藏") { print("收藏") }
            Button("😊 表情包") { print("表情包") }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $showUsageStatistics) {
            if toolbarCapabilities.showsUsageStats {
                UsageStatisticsView(client: viewModel.clawdBotClient, sessionKey: viewModel.currentSessionKey)
                    .scrollIndicators(.hidden)
            }
        }
        .sheet(isPresented: $showCronJobs) {
            if toolbarCapabilities.showsCronJobs {
                CronJobsView(client: viewModel.clawdBotClient)
                    .scrollIndicators(.hidden)
            }
        }
        .sheet(isPresented: $showSettings) {
            if toolbarCapabilities.showsSettings {
                ModelConfigView(client: viewModel.clawdBotClient)
                    .scrollIndicators(.hidden)
            }
        }
        .sheet(isPresented: $showSkillsSheet) {
            if toolbarCapabilities.showsSkills {
                OpenClawSkillsSheet(
                    client: viewModel.clawdBotClient
                )
                .scrollIndicators(.hidden)
            }
        }
        .sheet(isPresented: $showTitleRenameSheet) {
            sessionTitleRenameSheet
        }
        .sheet(isPresented: $showThinkingLevel) {
            if toolbarCapabilities.showsThinkingControl {
                ThinkingLevelSheet(
                    client: viewModel.clawdBotClient,
                    sessionKey: viewModel.currentSessionKey,
                    initialLevel: viewModel.currentThinkingLevel,
                    onApplied: { newLevel in
                        viewModel.updateCurrentThinkingLevel(newLevel)
                    }
                )
                .scrollIndicators(.hidden)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
        }
        .overlay { connectingOverlayView }
    }

    // MARK: - Subviews

    @ViewBuilder
    private var otherChannelBannerView: some View {
        if viewModel.otherChannelActive {
            HStack {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                if viewModel.activeChannels.isEmpty {
                    Text("其他渠道正在对话中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    let names = viewModel.activeChannels.map { localizedChannelName($0) }.joined(separator: "、")
                    Text("\(names) 正在对话中...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color(.systemGray6))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(viewModel.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                            .padding(.leading, 16)
                            .padding(.trailing, message.isUser ? 12 : 16)
                    }
                    if viewModel.agentState != .idle {
                        agentStateFooterView
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomScrollAnchorId)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ChatBottomAnchorMaxYPreferenceKey.self,
                                    value: geometry.frame(in: .named(messagesScrollSpaceName)).maxY
                                )
                            }
                        )
                }
                .padding(.vertical)
            }
            .coordinateSpace(name: messagesScrollSpaceName)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ChatScrollViewportHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                isInputFocused = false
                showAttachmentPicker = false
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
            .onPreferenceChange(ChatBottomAnchorMaxYPreferenceKey.self) { value in
                if abs(bottomAnchorMaxY - value) > 0.5 {
                    bottomAnchorMaxY = value
                }
                updateBottomAnchorVisibility(anchorMaxY: value)
            }
            .onPreferenceChange(ChatScrollViewportHeightPreferenceKey.self) { value in
                if abs(scrollViewportHeight - value) > 0.5 {
                    scrollViewportHeight = value
                    updateBottomAnchorVisibility(anchorMaxY: bottomAnchorMaxY)
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 10).onChanged { _ in
                    if isInputFocused {
                        isInputFocused = false
                        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    }
                }
            )
            .onChange(of: viewModel.messages.count) { _, _ in
                if !viewModel.messages.isEmpty {
                    guard isBottomAnchorVisible || viewModel.messages.count == 1 else { return }
                    performAutoScroll(proxy, animated: true, throttled: false)
                }
            }
            .onChange(of: viewModel.messages.last?.text) { _, _ in
                if let lastMessage = viewModel.messages.last, lastMessage.isStreaming {
                    guard isBottomAnchorVisible else { return }
                    performAutoScroll(proxy, animated: false, throttled: true)
                }
            }
            .onChange(of: isInputFocused) { _, newValue in
                if newValue {
                    // 键盘弹起时滚动到底部
                    if !viewModel.messages.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            performAutoScroll(proxy, animated: true, throttled: false)
                        }
                    }

                    // 关闭附件选择器
                    if showAttachmentPicker {
                        showAttachmentPicker = false
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if shouldShowScrollToBottomButton {
                    Button {
                        isBottomAnchorVisible = true
                        performAutoScroll(proxy, animated: true, throttled: false)
                    } label: {
                        Image(systemName: "arrow.down.to.line.compact")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.blue))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .padding(.bottom, 72)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
    }

    private var shouldShowScrollToBottomButton: Bool {
        !viewModel.messages.isEmpty && !isBottomAnchorVisible
    }

    private func updateBottomAnchorVisibility(anchorMaxY: CGFloat) {
        guard scrollViewportHeight > 0 else { return }
        let threshold: CGFloat = 24
        let visible = anchorMaxY <= (scrollViewportHeight + threshold)
        if visible != isBottomAnchorVisible {
            isBottomAnchorVisible = visible
        }
    }

    private func performAutoScroll(
        _ proxy: ScrollViewProxy,
        animated: Bool,
        throttled: Bool
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        if throttled, (now - lastAutoScrollTimestamp) < autoScrollThrottleInterval {
            return
        }
        lastAutoScrollTimestamp = now

        if animated {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo(bottomScrollAnchorId, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                proxy.scrollTo(bottomScrollAnchorId, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var agentStateFooterView: some View {
        HStack {
            AgentStateIndicator(state: viewModel.agentState)
                .padding(.leading, 16)
            Spacer()
        }
    }

    @ViewBuilder
    private var inputHeaderSectionView: some View {
        if viewModel.recordingState == .idle && !viewModel.isHoldingSpeakButton && viewModel.inputText.isEmpty {
            Divider()
        }
        toolbarSectionView
    }

    @ViewBuilder
    private var toolbarSectionView: some View {
        if !viewModel.showCommandPalette && !viewModel.isMeetingRecording {
            HStack(spacing: 0) {
                ChatToolbar(
                    recordingState: $viewModel.recordingState,
                    onShowSkills: toolbarCapabilities.showsSkills ? { showSkillsSheet = true } : nil,
                    onShowUsageStats: toolbarCapabilities.showsUsageStats ? { showUsageStatistics = true } : nil,
                    onShowCronJobs: toolbarCapabilities.showsCronJobs ? { showCronJobs = true } : nil,
                    onShowSettings: toolbarCapabilities.showsSettings ? { showSettings = true } : nil,
                    onShowThinking: toolbarCapabilities.showsThinkingControl ? { showThinkingLevel = true } : nil,
                    thinkingLabel: toolbarCapabilities.showsThinkingControl ? toolbarThinkingLabel : nil,
                    showLeftPadding: true
                )
                .disabled(!viewModel.isConnected)
                .opacity(viewModel.isConnected ? 1.0 : 0.5)
            }
            .frame(height: 44)
            .opacity(viewModel.recordingState == .idle && !viewModel.isHoldingSpeakButton ? 1.0 : 0.0)
            .offset(y: viewModel.recordingState == .idle && !viewModel.isHoldingSpeakButton ? 0 : -10)
            .animation(.easeInOut(duration: 0.25), value: viewModel.recordingState)
            .animation(.easeInOut(duration: 0.25), value: viewModel.isHoldingSpeakButton)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    private var toolbarThinkingLabel: String {
        let normalizedLevel = ThinkingLevel.from(raw: viewModel.currentThinkingLevel)
        return "思考·\(normalizedLevel.shortDisplayName)"
    }

    private var toolbarCapabilities: ChatToolbarCapabilities {
        viewModel.chatPlugin.toolbarCapabilities
    }

    @ViewBuilder
    private var inputSectionView: some View {
        ZStack(alignment: .bottom) {
            ChatInputBar(
                inputText: $viewModel.inputText,
                isInputFocused: $isInputFocused,
                inputMode: $viewModel.inputMode,
                recordingState: $viewModel.recordingState,
                recordingDuration: $viewModel.recordingDuration,
                recognizedText: $viewModel.realtimeTranscript,
                partialText: $viewModel.partialTranscript,
                isConnected: viewModel.isConnected,
                isRecognizing: viewModel.isRecognizingAudio,
                isMeetingRecording: viewModel.isMeetingRecording,
                meetingPhase: $viewModel.meetingPhase,
                selectedAttachments: $selectedAttachments,
                showAttachmentPicker: $showAttachmentPicker,
                accessory: ChatComposerAccessory(
                    hasActiveRuns: viewModel.hasActiveRuns,
                    showsAttachmentButton: true,
                    onStopRun: {
                        Task { await viewModel.stopOldestRun() }
                    }
                ),
                onSend: {
                    isInputFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    viewModel.sendMessage(attachments: selectedAttachments)
                    selectedAttachments.removeAll()
                },
                onCancelRecording: {
                    // 根据当前状态调用正确的取消函数
                    if viewModel.isHoldingSpeakButton {
                        // Hold-to-speak 录音
                        viewModel.cancelHoldToSpeakRecording()
                    } else if viewModel.isMeetingRecording {
                        // 会议录音
                        withAnimation(AnimationConfig.recordingSpring) {
                            viewModel.cancelMeetingRecording()
                        }
                    }
                },
                onSendRecording: {
                    isInputFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    Task { await viewModel.finishMeetingRecording() }
                },
                onHoldStartRecording: { viewModel.startHoldToSpeakRecording() },
                onHoldSendRecording: {
                    isInputFocused = false
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    Task { await viewModel.finishHoldToSpeakRecording() }
                },
                onStartMeetingRecording: { viewModel.startMeetingRecording() },
                onPauseMeetingRecording: { viewModel.pauseMeetingRecording() },
                onResumeMeetingRecording: { viewModel.resumeMeetingRecording() },
                onMeetingRecording: { viewModel.showMeetingRecordingCard() },
                onDismissMeetingRecording: {
                    withAnimation(AnimationConfig.recordingSpring) { viewModel.dismissMeetingRecording() }
                },
                isHoldingSpeakButton: $viewModel.isHoldingSpeakButton
            )
            .onChange(of: viewModel.inputText) { _, _ in viewModel.updateCommandPalette() }

            if viewModel.showCommandPalette {
                VStack {
                    Spacer()
                    CommandPaletteView(
                        commands: viewModel.filteredCommands,
                        onSelect: { command in
                            isInputFocused = false
                            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                            viewModel.executeCommand(command)
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .animation(.spring(response: 0.3, dampingFraction: 0.8), value: viewModel.showCommandPalette)
            }
        }
    }

    @ViewBuilder
    private var connectingOverlayView: some View {
        if viewModel.isConnecting && !viewModel.isConnected {
            ZStack {
                Color.primary.opacity(colorScheme == .dark ? 0.5 : 0.4)
                    .ignoresSafeArea()
                VStack(spacing: 20) {
                    ZStack {
                        ForEach(0..<3) { index in
                            Circle()
                                .stroke(
                                    LinearGradient(colors: [Color.blue.opacity(0.6), Color.cyan.opacity(0.6)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                                    lineWidth: 3
                                )
                                .frame(width: 80, height: 80)
                                .scaleEffect(1.0 + CGFloat(index) * 0.3)
                                .opacity(0.8 - Double(index) * 0.25)
                                .animation(
                                    Animation.easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                                        .delay(Double(index) * 0.2),
                                    value: viewModel.isConnecting
                                )
                        }
                        Image("AppLogoSmall")
                            .resizable().scaledToFit()
                            .frame(width: 60, height: 60)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(spacing: 8) {
                        Text("正在连接...")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.primary)
                        if let bot = viewModel.bot {
                            Text(bot.uiDisplayName)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(40)
                .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(.ultraThinMaterial))
                .shadow(color: Color.primary.opacity(0.2), radius: 20, x: 0, y: 10)
            }
            .transition(.opacity)
        }
    }

    // MARK: - Navigation Toolbar Items

    private var navigationLeadingItem: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                if let onDismiss = onDismiss { onDismiss() } else { dismiss() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("返回")
                        .font(.system(size: 17))
                }
                .foregroundColor(.blue)
            }
        }
    }

    private var navigationTitleItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let bot = viewModel.bot {
                let trimmedCustomTitle = customSessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedSessionTitle = sessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayTitle = (trimmedCustomTitle?.isEmpty == false)
                    ? trimmedCustomTitle!
                    : ((trimmedSessionTitle?.isEmpty == false) ? trimmedSessionTitle! : bot.uiDisplayName)
                HStack(spacing: 6) {
                    ZStack(alignment: .topLeading) {
                        Image(bot.channelType.logoName)
                            .resizable().scaledToFit()
                            .frame(width: 24, height: 24)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Circle()
                            .fill(connectionStatusColor)
                            .frame(width: 8, height: 8)
                            .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                            .shadow(radius: 1)
                            .offset(x: -2, y: -2)
                    }
                    .frame(width: 24, height: 24)
                    Text(displayTitle)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.45) {
                    openTitleRenameSheet(currentTitle: displayTitle)
                }
            } else {
                Text("AI 助手")
                    .font(.system(size: 16, weight: .semibold))
            }
        }
    }

    // MARK: - Helper Methods

    /// Status bar blur effect
    @ViewBuilder
    private var statusBarBlur: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: 0) // Status bar height handled by safe area
            .ignoresSafeArea(edges: .top)
    }

    /// Connection status color
    private var connectionStatusColor: Color {
        if viewModel.isConnected {
            return .green
        } else if viewModel.isConnecting {
            return .orange
        } else {
            return .red
        }
    }

    /// 将渠道名称映射为本地化的中文名称
    private func localizedChannelName(_ channel: String) -> String {
        let channelMap: [String: String] = [
            "feishu": "飞书",
            "telegram": "Telegram",
            "discord": "Discord",
            "wechat": "微信",
            "slack": "Slack",
            "other": "其他"
        ]

        return channelMap[channel.lowercased()] ?? channel.capitalized
    }

    private var sessionTitleRenameSheet: some View {
        NavigationStack {
            Form {
                Section("会话标题") {
                    TextField("输入自定义标题", text: $pendingTitleInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                }
            }
            .navigationTitle("自定义标题")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showTitleRenameSheet = false
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        saveSessionTitle()
                    }
                    .disabled(pendingTitleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    private func openTitleRenameSheet(currentTitle: String) {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        pendingTitleInput = currentTitle
        showTitleRenameSheet = true
    }

    private func saveSessionTitle() {
        let trimmed = pendingTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let existing = customSessionTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed == existing {
            showTitleRenameSheet = false
            return
        }

        showTitleRenameSheet = false

        Task {
            do {
                guard let sessionId = viewModel.currentStorageSessionId else {
                    throw NSError(
                        domain: "ChatView",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "无法定位当前会话 ID"]
                    )
                }
                guard var session = try await sessionRepository.getSession(id: sessionId) else {
                    throw NSError(
                        domain: "ChatView",
                        code: 2,
                        userInfo: [NSLocalizedDescriptionKey: "本地会话不存在，无法更新标题"]
                    )
                }

                session.title = trimmed
                session.updatedAt = Date()
                try await sessionRepository.updateSession(session)

                await MainActor.run {
                    customSessionTitle = trimmed
                    NotificationCenter.default.post(
                        name: NSNotification.Name("ContextGoSessionUpdated"),
                        object: nil,
                        userInfo: [
                            "sessionId": session.id,
                            "agentId": session.agentId,
                            "title": trimmed,
                            "reason": "title_renamed"
                        ]
                    )
                }
            } catch {
                await MainActor.run {
                    viewModel.errorMessage = "更新会话标题失败: \(error.localizedDescription)"
                    viewModel.showError = true
                }
            }
        }
    }
}

private struct ChatBottomAnchorMaxYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatScrollViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#Preview {
    NavigationView {
        ChatView()
    }
}
