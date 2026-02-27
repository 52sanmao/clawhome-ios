//
//  SessionDetailView.swift
//  contextgo
//
//  CLI session chat interface - full-featured native chat
//

import SwiftUI
import UIKit
import Combine

struct SessionDetailView: View {
    let session: CLISession
    var onDismiss: (() -> Void)? = nil
    @ObservedObject private var client: RelayClient

    @State private var sessionSnapshot: CLISession
    @State private var liveTitleOverride: String?
    @StateObject private var viewModel: CLISessionViewModel
    @FocusState private var isInputFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @State private var showSettings = false
    @State private var showSessionInfo = false
    @State private var runtimeMode = RuntimePermissionMode.safeYolo
    @State private var runtimeSupportedPermissionModes: [RuntimePermissionMode] = []
    @State private var runtimePermissionModeId: String?
    @State private var runtimeSupportedPermissionModeIds: [String] = []
    @State private var runtimeControlMode = RuntimeControlMode.remote
    @State private var runtimeModelDisplay: String?
    @State private var runtimeReasoningEffort: CodexReasoningEffortOption = .medium
    @State private var runtimeSupportedReasoningEfforts: [CodexReasoningEffortOption] = CodexReasoningEffortOption.defaultOptions
    @State private var opencodeModeId: String?
    @State private var opencodeAvailableModes: [OpenCodeModeOption] = []
    @State private var opencodeModelId: String?
    @State private var opencodeVariant: String?
    @State private var opencodeAvailableVariants: [String] = []
    @State private var opencodeOmoDetected = false
    @State private var opencodeOmoRegistered = false
    @State private var opencodeOmoEntry: String?
    @State private var opencodeOmoModeHints: [String] = []
    @State private var showReasoningEffortDialog = false
    @State private var showOpenCodeModeSheet = false
    @State private var showOpenCodeVariantSheet = false
    @State private var isRuntimeReasoningUpdating = false
    @State private var isOpenCodeModeUpdating = false
    @State private var isOpenCodeVariantUpdating = false
    @State private var isRuntimeModeUpdating = false
    @State private var isRawRuntimeModeUpdating = false
    @State private var runtimeModeUpdateError: String?
    @State private var showRuntimeConfigToast = false
    @State private var runtimeConfigToastText = ""
    @State private var runtimeConfigToastDismissTask: Task<Void, Never>?
    @State private var settingsPreferSkillsTab = false
    @State private var mcpToolNames: [String] = []
    @State private var sessionSkills: [CLISession.Metadata.Runtime.Skill] = []
    @State private var skillAvailableCount: Int = 0
    @State private var skillLoadedCount: Int = 0
    @State private var loadedSkillUris: [String] = []
    @State private var skillLoadState: String = "idle"
    @State private var skillLastSyncAt: Date?
    @State private var skillLastError: String?
    @State private var composerSelectedSkillUri: String?
    @State private var composerSelectedSkillName: String?
    @State private var isSkillListRefreshing = false
    @State private var skillActionError: String?
    @State private var isReplayRefreshing = false
    @State private var replayRefreshError: String?
    @State private var runtimeConfigAvailable = true
    @State private var isContextGoLinked = true
    @State private var connectedSpaceIds: Set<String> = []
    @State private var availableSpaces: [Space] = []
    @State private var showSpaceSelection = false
    @State private var showActiveTodoSheet = false
    @State private var showTitleRenameSheet = false
    @State private var pendingTitleInput = ""

    @State private var selectedAttachments: [AttachmentItem] = []
    @State private var showAttachmentPicker = false
    @State private var meetingPhase: MeetingRecordingPhase = .ready
    @State private var recordingState: RecordingState = .idle
    @State private var renderedRunGroups: [CLIRunGroup] = []
    @State private var renderedRunGroupsVersion: Int = 0
    @State private var runGroupBuildTask: Task<Void, Never>?
    @State private var runGroupBuildGeneration: Int = 0
    @State private var lastRenderedMessageIDs: [String] = []
    @State private var visibleRunGroupLimit: Int = 36
    @State private var hasPerformedInitialAutoScroll = false
    @State private var scrollViewportHeight: CGFloat = 0
    @State private var bottomAnchorMaxY: CGFloat = 0
    @State private var isBottomAnchorVisible = true
    @State private var lastAutoScrollTimestamp: CFAbsoluteTime = 0
    private let bottomScrollAnchorId = "cli-scroll-bottom-anchor"
    private let messagesScrollSpaceName = "cli-messages-scroll-space"
    private let autoScrollThrottleInterval: CFAbsoluteTime = 0.12
    private let runGroupPageSize: Int = 24
    private let sessionRepository = LocalSessionRepository.shared

    private var isClaudeSession: Bool {
        sessionSnapshot.metadata?.flavor?.caseInsensitiveCompare("claude") == .orderedSame
    }

    private var isCodexSession: Bool {
        bridgeProvider == .codex
    }

    private var isOpenCodeSession: Bool {
        bridgeProvider == .opencode
    }

    private var bridgeProvider: CoreSessionEventProvider {
        let runtimeProvider = sessionSnapshot.metadata?.runtime?.provider?.trimmingCharacters(in: .whitespacesAndNewlines)
        let flavor = sessionSnapshot.metadata?.flavor?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CoreSessionEventProvider.fromRuntimeValue(runtimeProvider ?? flavor)
    }

    private var supportsRuntimeStatusSlot: Bool {
        bridgeProvider == .codex || bridgeProvider == .opencode
    }

    private var renderProviderFlavor: String? {
        if let flavor = sessionSnapshot.metadata?.flavor?.trimmingCharacters(in: .whitespacesAndNewlines),
           !flavor.isEmpty {
            return flavor
        }

        if let runtimeProvider = sessionSnapshot.metadata?.runtime?.provider?.trimmingCharacters(in: .whitespacesAndNewlines),
           !runtimeProvider.isEmpty {
            return runtimeProvider
        }

        switch bridgeProvider {
        case .codex:
            return "codex"
        case .opencode:
            return "opencode"
        case .claudecode:
            return "claude"
        case .geminicli:
            return "gemini"
        default:
            return nil
        }
    }

    private var contextGoLinkedKey: String {
        "cli.contextgo.linked.\(client.ownerAgentId)"
    }

    private var contextGoSpacesKey: String {
        "cli.contextgo.spaces.\(client.ownerAgentId)"
    }

    private var agentLogoName: String {
        switch sessionSnapshot.metadata?.flavor?.lowercased() {
        case "codex":
            return AgentChannelType.codex.logoName
        case "opencode":
            return AgentChannelType.openCode.logoName
        case "gemini":
            return AgentChannelType.geminiCLI.logoName
        default:
            return AgentChannelType.claudeCode.logoName
        }
    }

    init(session: CLISession, client: RelayClient, onDismiss: (() -> Void)? = nil) {
        self.session = session
        self.onDismiss = onDismiss
        let initialRuntimeMode: RuntimePermissionMode = {
            switch session.metadata?.flavor?.lowercased() {
            case "codex":
                return .defaultMode
            case "claude":
                return .defaultMode
            default:
                return .safeYolo
            }
        }()
        _sessionSnapshot = State(initialValue: session)
        _client = ObservedObject(wrappedValue: client)
        _runtimeMode = State(initialValue: initialRuntimeMode)
        _viewModel = StateObject(wrappedValue: CLISessionViewModel(session: session, client: client))
    }

    var body: some View {
        overlayContent
    }

    private var baseContent: some View {
        rootContent
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                leadingToolbarItem
                principalToolbarItem
                trailingToolbarItem
            }
            .alert("错误", isPresented: $viewModel.showError) {
                Button("确定", role: .cancel) { }
            } message: {
                if let error = viewModel.errorMessage {
                    Text(error)
                }
            }
    }

    private var sheetContent: some View {
        baseContent
            .sheet(isPresented: $showSettings) { settingsSheetView }
            .sheet(isPresented: $showSpaceSelection) { spaceSelectionSheetView }
            .sheet(isPresented: $showSessionInfo) { sessionInfoSheetView }
            .sheet(isPresented: $showActiveTodoSheet) { activeTodoSheetView }
            .sheet(isPresented: $showTitleRenameSheet) { sessionTitleRenameSheet }
            .sheet(isPresented: $showOpenCodeModeSheet) { openCodeModeSheetView }
            .sheet(isPresented: $showOpenCodeVariantSheet) { openCodeVariantSheetView }
    }

    private var dialogContent: some View {
        sheetContent
            .confirmationDialog(
                "思考级别",
                isPresented: $showReasoningEffortDialog,
                titleVisibility: .visible
            ) {
                ForEach(runtimeSupportedReasoningEfforts, id: \.rawValue) { effort in
                    Button(effort.dialogTitle) {
                        Task { await updateRuntimeReasoningEffort(effort) }
                    }
                }
                Button("取消", role: .cancel) { }
            } message: {
                Text("当前：\(runtimeReasoningEffort.displayName)")
            }
    }

    private var lifecycleContent: some View {
        dialogContent
            .onDisappear {
                handleDisappear()
                runtimeConfigToastDismissTask?.cancel()
                runGroupBuildTask?.cancel()
            }
            .task(id: session.id) {
                await initializeSessionView()
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CLISessionUpdated"))) { notification in
                handleSessionUpdatedNotification(notification)
            }
            .onReceive(
                viewModel.$messages
                    .debounce(for: .milliseconds(120), scheduler: RunLoop.main)
            ) { messages in
                rebuildRunGroups(from: messages)
            }
            .onAppear {
                rebuildRunGroups(from: viewModel.messages)
            }
            .onChange(of: isContextGoLinked) { _, value in
                UserDefaults.standard.set(value, forKey: contextGoLinkedKey)
            }
            .onChange(of: connectedSpaceIds) { _, value in
                UserDefaults.standard.set(Array(value).sorted(), forKey: contextGoSpacesKey)
            }
            .onChange(of: viewModel.inputText) { oldValue, newValue in
                handleComposerInputChange(oldValue: oldValue, newValue: newValue)
            }
            .onChange(of: viewModel.activeTodoSnapshot) { _, snapshot in
                if snapshot == nil {
                    showActiveTodoSheet = false
                }
            }
    }

    private var overlayContent: some View {
        lifecycleContent
            .overlay(alignment: .top) {
                if showRuntimeConfigToast {
                    ToastView(message: runtimeConfigToastText)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
    }

    private var rootContent: some View {
        ChatScreenShell(
            topBanner: { EmptyView() },
            timeline: { messagesScrollView },
            inputHeader: {
                if showsSkillSlashPalette {
                    EmptyView()
                } else {
                    runtimeStatusTitleView
                }
            },
            composer: { inputBarView }
        )
    }

    private var inputBarView: some View {
        VStack(spacing: 8) {
            if showsSkillSlashPalette {
                CLISkillSlashPaletteView(
                    skills: filteredSlashSkills,
                    onSelect: { skill in
                        selectSkillFromSlash(skill)
                    }
                )
                .padding(.horizontal, 16)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            ChatInputBar(
                inputText: $viewModel.inputText,
                isInputFocused: $isInputFocused,
                inputMode: $viewModel.inputMode,
                recordingState: $recordingState,
                recordingDuration: $viewModel.recordingDuration,
                recognizedText: .constant(""),
                partialText: .constant(""),
                isConnected: true,
                isRecognizing: viewModel.isRecognizing,
                isMeetingRecording: false,
                meetingPhase: $meetingPhase,
                highlightLeadingSkillToken: true,
                selectedSkillName: composerSelectedSkillName,
                onClearSelectedSkill: {
                    composerSelectedSkillUri = nil
                    composerSelectedSkillName = nil
                },
                selectedAttachments: $selectedAttachments,
                showAttachmentPicker: $showAttachmentPicker,
                accessory: ChatComposerAccessory(
                    hasActiveRuns: viewModel.hasActiveRun,
                    isStoppingRun: viewModel.isAborting,
                    showsAttachmentButton: false,
                    onStopRun: {
                        Task { await viewModel.abortCurrentRun() }
                    },
                    onOpenSettings: openSettingsSheet
                ),
                onSend: sendCurrentMessage,
                onCancelRecording: {
                    viewModel.cancelHoldToSpeakRecording()
                },
                onSendRecording: {
                    Task { await viewModel.finishHoldToSpeakRecording() }
                },
                onHoldStartRecording: {
                    viewModel.startHoldToSpeakRecording()
                },
                onHoldSendRecording: {
                    Task { await viewModel.finishHoldToSpeakRecording() }
                },
                onStartMeetingRecording: { },
                onPauseMeetingRecording: { },
                onResumeMeetingRecording: { },
                onMeetingRecording: nil,
                isHoldingSpeakButton: $viewModel.isHoldingSpeakButton
            )
            .onChange(of: showAttachmentPicker) { _, opened in
                if opened {
                    // CLI 原生页面当前不支持附件上传，强制关闭 picker 防止空链路。
                    showAttachmentPicker = false
                }
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: showsSkillSlashPalette)
    }

    @ViewBuilder
    private var runtimeStatusTitleView: some View {
        VStack(spacing: 6) {
            if supportsRuntimeStatusSlot && viewModel.hasActiveRun {
                AgentRuntimeStatusSlotView(title: activeRunTitleText)
                    .padding(.horizontal, 16)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ContextGoLinkBadgeButton(
                        agentLogoName: agentLogoName,
                        isLinked: isContextGoLinked,
                        connectedSpaceCount: connectedSpaceIds.count
                    ) {
                        showSpaceSelection = true
                    }
                    .fixedSize(horizontal: true, vertical: false)

                    runtimeControlModeBadge

                    skillRuntimeBadge

                    if supportsCodexReasoningControl {
                        Button {
                            showReasoningEffortDialog = true
                        } label: {
                            HStack(spacing: 5) {
                                if isRuntimeReasoningUpdating {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "brain")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                Text("思考 \(runtimeReasoningEffort.compactLabel)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundColor(.purple)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.purple.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isRuntimeReasoningUpdating)
                    }

                    if supportsOpenCodeVariantControl {
                        Button {
                            showOpenCodeVariantSheet = true
                        } label: {
                            HStack(spacing: 5) {
                                if isOpenCodeVariantUpdating {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "brain")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                Text("思考 \(openCodeVariantCompactLabel)")
                                    .font(.system(size: 11, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundColor(.purple)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.purple.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isOpenCodeVariantUpdating)
                    }

                    if isOpenCodeSession {
                        openCodePluginBadge
                    }

                    if let todo = viewModel.activeTodoSnapshot {
                        Text("·")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: true, vertical: false)

                        Button {
                            showActiveTodoSheet = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "checklist")
                                    .font(.system(size: 11, weight: .semibold))
                                Text("TODO \(todo.completedCount)/\(todo.totalCount)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundColor(.blue)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(Color.blue.opacity(0.12))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    if let contextRemainingPercent = normalizedContextRemainingPercent {
                        HStack(spacing: 6) {
                            Image(systemName: "gauge.with.dots.needle.33percent")
                                .font(.system(size: 11, weight: .semibold))
                            Text("上下文 \(Int(contextRemainingPercent.rounded()))%")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .lineLimit(1)
                        }
                        .fixedSize(horizontal: true, vertical: false)
                        .foregroundColor(contextRemainingColor(for: contextRemainingPercent))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(contextRemainingColor(for: contextRemainingPercent).opacity(0.12))
                        )
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 1)
            }
        }
        .padding(.bottom, 6)
        .opacity(shouldShowRuntimeStatusTitle ? 1.0 : 0.0)
        .offset(y: shouldShowRuntimeStatusTitle ? 0 : -8)
        .animation(.easeInOut(duration: 0.25), value: recordingState)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isHoldingSpeakButton)
        .animation(.easeInOut(duration: 0.25), value: viewModel.isRecognizing)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    private var shouldShowRuntimeStatusTitle: Bool {
        !showsSkillSlashPalette
            && (
                viewModel.hasActiveRun
                    || (
                        recordingState == .idle
                        && !viewModel.isHoldingSpeakButton
                        && !viewModel.isRecognizing
                    )
            )
    }

    private var normalizedContextRemainingPercent: Double? {
        guard let raw = sessionSnapshot.metadata?.runtime?.contextRemainingPercent,
              raw.isFinite else {
            return nil
        }

        let percent = raw <= 1.0 ? raw * 100.0 : raw
        return min(max(percent, 0), 100)
    }

    private func contextRemainingColor(for percent: Double) -> Color {
        switch percent {
        case ..<10:
            return .red
        case ..<25:
            return .orange
        default:
            return .blue
        }
    }

    private var activeRunTitleText: String {
        let normalized = viewModel.runtimeStateTitle?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? "Working" : normalized
    }

    @ViewBuilder
    private var runtimeControlModeBadge: some View {
        if supportsOpenCodeModeControl || runtimeConfigAvailable {
            Button {
                if supportsOpenCodeModeControl {
                    showOpenCodeModeSheet = true
                } else {
                    openSettingsSheet()
                }
            } label: {
                runtimeControlModeBadgeContent
            }
            .buttonStyle(.plain)
            .disabled(isOpenCodeModeUpdating)
        } else {
            runtimeControlModeBadgeContent
        }
    }

    private var runtimeControlModeBadgeContent: some View {
        HStack(spacing: 4) {
            Image(systemName: runtimeControlMode == .local ? "desktopcomputer" : "iphone")
                .font(.system(size: 10, weight: .semibold))
            Text(runtimePermissionModeCompactLabel)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundColor(runtimeControlMode.tintColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(runtimeControlMode.tintColor.opacity(0.12))
        )
    }

    private var effectiveSkillAvailableCount: Int {
        if skillAvailableCount > 0 {
            return skillAvailableCount
        }
        return sessionSnapshot.metadata?.runtime?.skillAvailableCount ?? 0
    }

    private var effectiveSkillLoadedCount: Int {
        if skillLoadedCount > 0 {
            return skillLoadedCount
        }
        return sessionSnapshot.metadata?.runtime?.skillLoadedCount ?? 0
    }

    private var skillRuntimeBadgeTint: Color {
        switch skillLoadState.lowercased() {
        case "ready":
            return .green
        case "loading":
            return .orange
        case "error":
            return .red
        default:
            return .secondary
        }
    }

    private var skillRuntimeBadge: some View {
        Button {
            openSettingsSheet(preferSkillsTab: true)
        } label: {
            skillRuntimeBadgeContent
        }
        .buttonStyle(.plain)
    }

    private var skillRuntimeBadgeContent: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.system(size: 10, weight: .semibold))
            Text("技能 \(effectiveSkillLoadedCount)/\(effectiveSkillAvailableCount)")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundColor(skillRuntimeBadgeTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(skillRuntimeBadgeTint.opacity(0.12))
        )
    }

    private var runtimePermissionModeCompactLabel: String {
        if isOpenCodeSession {
            return openCodeModeCompactLabel
        }
        if let rawModeId = runtimePermissionModeId,
           !rawModeId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return rawModeId
        }

        switch runtimeMode {
        case .readOnly:
            return "read-only"
        case .defaultMode:
            return isCodexSession ? "workspace-write" : "default"
        case .fullAccess:
            return "danger-full-access"
        case .safeYolo:
            return "safe-yolo"
        case .acceptEdits:
            return "acceptEdits"
        case .plan:
            return "plan"
        case .yolo:
            return "yolo"
        case .dontAsk:
            return "dontAsk"
        case .bypassPermissions:
            return "bypassPermissions"
        }
    }

    private var supportsCodexReasoningControl: Bool {
        isCodexSession && runtimeConfigAvailable
    }

    private var supportsOpenCodeModeControl: Bool {
        isOpenCodeSession && runtimeConfigAvailable
    }

    private var supportsOpenCodeVariantControl: Bool {
        isOpenCodeSession && runtimeConfigAvailable
            && (!opencodeAvailableVariants.isEmpty || opencodeVariant != nil)
    }

    private var openCodeModeDisplayName: String {
        if let modeId = opencodeModeId,
           let mode = opencodeAvailableModes.first(where: { $0.id == modeId }) {
            return mode.name
        }
        return opencodeModeId ?? "default"
    }

    private var openCodeModeCompactLabel: String {
        openCodeModeDisplayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
            ? "default"
            : openCodeModeDisplayName
    }

    private var openCodeVariantDisplayName: String {
        if let variant = opencodeVariant,
           !variant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return variant
        }
        return OpenCodeVariantOption.defaultValue
    }

    private var openCodeVariantCompactLabel: String {
        openCodeVariantDisplayName
    }

    private var normalizedOpenCodeVariantSelection: String {
        let normalized = opencodeVariant?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (normalized?.isEmpty == false) ? normalized! : OpenCodeVariantOption.defaultValue
    }

    private var openCodeVariantDialogOptions: [String] {
        var options: [String] = [OpenCodeVariantOption.defaultValue]
        for variant in opencodeAvailableVariants {
            let normalized = variant.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty { continue }
            if !options.contains(normalized) {
                options.append(normalized)
            }
        }
        return options
    }

    private func openCodeVariantDialogTitle(for variant: String) -> String {
        if variant == OpenCodeVariantOption.defaultValue {
            return "默认（default）"
        }
        return "\(variant)"
    }

    private var openCodePluginBadge: some View {
        let tint: Color = opencodeOmoDetected ? .green : .orange
        let text: String = {
            if !opencodeOmoDetected { return "OMO 未检测" }
            if opencodeOmoRegistered { return "OMO 已注册" }
            return "OMO 疑似启用"
        }()

        return HStack(spacing: 5) {
            Image(systemName: opencodeOmoDetected ? "checkmark.seal.fill" : "questionmark.circle")
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
        .foregroundColor(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .onTapGesture {
            if let entry = opencodeOmoEntry, !entry.isEmpty {
                showRuntimeToast("oh-my-opencode: \(entry)")
            } else if !opencodeOmoModeHints.isEmpty {
                showRuntimeToast("疑似 OMO agents: \(opencodeOmoModeHints.joined(separator: ", "))")
            } else {
                showRuntimeToast("未检测到 oh-my-opencode 注册")
            }
        }
    }

    private var leadingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                handleBack()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 17))
                }
                .foregroundColor(.blue)
            }
        }
    }

    private var principalToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(currentDisplayTitle)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.45) {
                    openTitleRenameSheet()
                }
        }
    }

    private var trailingToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .navigationBarTrailing) {
            HStack(spacing: 12) {
                contextGoToggleButton

                Button {
                    showSessionInfo = true
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
    }

    private var settingsSheetView: some View {
        let rawModeId: String? = isOpenCodeSession ? opencodeModeId : runtimePermissionModeId
        let rawModeOptions: [RuntimeRawModeOption] = {
            if isOpenCodeSession {
                return opencodeAvailableModes.map { mode in
                    RuntimeRawModeOption(id: mode.id, name: mode.name, description: mode.description)
                }
            }
            if runtimeSupportedPermissionModeIds.isEmpty {
                return []
            }
            return runtimeSupportedPermissionModeIds.map { modeId in
                RuntimeRawModeOption(id: modeId, name: modeId, description: nil)
            }
        }()
        let rawModeUpdating = isOpenCodeSession ? isOpenCodeModeUpdating : isRawRuntimeModeUpdating
        let onUpdateRawMode: ((String) -> Void)? = {
            if isOpenCodeSession {
                return { modeId in
                    Task { await selectOpenCodeModeById(modeId) }
                }
            }
            if runtimeSupportedPermissionModeIds.isEmpty {
                return nil
            }
            return { modeId in
                Task { await updateRuntimePermissionModeById(modeId) }
            }
        }()

        return CLISessionSettings(
            runtimeMode: runtimeMode,
            runtimeModeOptions: supportedRuntimeModeOptions,
            isRuntimeModeUpdating: isRuntimeModeUpdating,
            runtimeModeUpdateError: runtimeModeUpdateError,
            onUpdateRuntimeMode: { mode in
                Task { await updateRuntimePermissionMode(mode) }
            },
            runtimeControlMode: runtimeControlMode,
            runtimeModel: runtimeModelDisplay ?? sessionSnapshot.metadata?.runtime?.model,
            mcpReady: sessionSnapshot.metadata?.runtime?.mcpReady ?? [],
            mcpFailed: sessionSnapshot.metadata?.runtime?.mcpFailed ?? [],
            mcpCancelled: sessionSnapshot.metadata?.runtime?.mcpCancelled ?? [],
            mcpToolNames: mcpToolNames,
            mcpStartupPhase: sessionSnapshot.metadata?.runtime?.mcpStartupPhase,
            mcpStartupUpdatedAt: sessionSnapshot.metadata?.runtime?.mcpStartupUpdatedAt,
            skillAvailableCount: skillAvailableCount,
            skillLoadedCount: skillLoadedCount,
            loadedSkillUris: loadedSkillUris,
            skillLoadState: skillLoadState,
            skillLastSyncAt: skillLastSyncAt,
            skillLastError: skillLastError,
            skills: sessionSkills,
            isSkillsRefreshing: isSkillListRefreshing,
            skillActionError: skillActionError,
            onRefreshSkills: {
                Task { await refreshSkillsFromServer() }
            },
            isReplayRefreshing: isReplayRefreshing,
            replayRefreshError: replayRefreshError,
            onReplayRefresh: {
                Task { await replayFromServerAfterClearingLocalCache() }
            },
            preferCodexPermissionNaming: isCodexSession,
            preferSkillsTab: settingsPreferSkillsTab,
            rawRuntimeModeId: rawModeId,
            rawRuntimeModeOptions: rawModeOptions,
            isRawRuntimeModeUpdating: rawModeUpdating,
            onUpdateRawRuntimeMode: onUpdateRawMode
        )
    }

    private var spaceSelectionSheetView: some View {
        SpaceSelectionSheet(
            selectedSpaceIds: $connectedSpaceIds,
            isContextGoEnabled: $isContextGoLinked,
            availableSpaces: availableSpaces,
            onConfirm: {
                showSpaceSelection = false
            },
            onClose: {
                showSpaceSelection = false
            }
        )
    }

    private var sessionInfoSheetView: some View {
        NavigationStack {
            SessionInfoView(
                session: sessionSnapshot,
                client: client,
                onSessionArchived: {
                    showSessionInfo = false
                    dismiss()
                },
                onSessionDeleted: {
                    showSessionInfo = false
                    dismiss()
                }
            )
        }
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
                        persistCustomTitle()
                    }
                    .disabled(pendingTitleInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
    }

    private var activeTodoSheetView: some View {
        NavigationStack {
            Group {
                if let snapshot = viewModel.activeTodoSnapshot {
                    List {
                        Section {
                            HStack {
                                Label("进行中", systemImage: "checklist")
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text("\(snapshot.completedCount)/\(snapshot.totalCount)")
                                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }

                        Section("任务清单") {
                            ForEach(snapshot.items) { item in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: todoStatusIcon(item.status))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundColor(todoStatusColor(item.status))
                                        .frame(width: 16)

                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.content)
                                            .font(.system(size: 14))
                                            .foregroundColor(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)

                                        if let priority = item.priority, !priority.isEmpty {
                                            Text("优先级: \(priority)")
                                                .font(.system(size: 11))
                                                .foregroundColor(.secondary)
                                        }
                                    }

                                    Text(todoStatusLabel(item.status))
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(todoStatusColor(item.status))
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "checklist")
                            .font(.system(size: 28))
                            .foregroundColor(.secondary)
                        Text("暂无进行中的 Todo")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Task / Todo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        showActiveTodoSheet = false
                    }
                }
            }
        }
    }

    private var openCodeModeSheetView: some View {
        NavigationStack {
            List {
                Section("当前：\(openCodeModeDisplayName)") {
                    if opencodeAvailableModes.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("暂未获取到可切换的 Agent 列表")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(.secondary)
                            if !opencodeOmoModeHints.isEmpty {
                                Text("检测到 OMO hints: \(opencodeOmoModeHints.joined(separator: ", "))")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        ForEach(opencodeAvailableModes) { mode in
                            Button {
                                Task { await selectOpenCodeMode(mode) }
                            } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(mode.name)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        if let description = mode.description,
                                           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                            Text(description)
                                                .font(.system(size: 12))
                                                .foregroundColor(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if mode.id == opencodeModeId {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(isOpenCodeModeUpdating)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("OpenCode 运行模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        showOpenCodeModeSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var openCodeVariantSheetView: some View {
        NavigationStack {
            List {
                Section("当前：\(openCodeVariantDisplayName)") {
                    ForEach(openCodeVariantDialogOptions, id: \.self) { variant in
                        Button {
                            Task { await selectOpenCodeVariant(variant) }
                        } label: {
                            HStack(spacing: 10) {
                                Text(openCodeVariantDialogTitle(for: variant))
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if normalizedOpenCodeVariantSelection == variant {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.blue)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(isOpenCodeVariantUpdating)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("OpenCode 思考模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        showOpenCodeVariantSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func todoStatusLabel(_ status: String) -> String {
        switch status.lowercased() {
        case "completed", "done", "success":
            return "已完成"
        case "in_progress", "running":
            return "进行中"
        default:
            return "待处理"
        }
    }

    private func todoStatusIcon(_ status: String) -> String {
        switch status.lowercased() {
        case "completed", "done", "success":
            return "checkmark.circle.fill"
        case "in_progress", "running":
            return "clock.fill"
        default:
            return "circle"
        }
    }

    private func todoStatusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "completed", "done", "success":
            return .green
        case "in_progress", "running":
            return .orange
        default:
            return .secondary
        }
    }

    private func openSettingsSheet() {
        openSettingsSheet(preferSkillsTab: false)
    }

    private func openSettingsSheet(preferSkillsTab: Bool) {
        runtimeModeUpdateError = nil
        replayRefreshError = nil
        skillActionError = nil
        settingsPreferSkillsTab = preferSkillsTab
        showSettings = true
        Task {
            await refreshSkillsFromServer()
        }
    }

    private func showRuntimeToast(_ message: String) {
        runtimeConfigToastDismissTask?.cancel()
        runtimeConfigToastText = message

        withAnimation(.spring(response: 0.3)) {
            showRuntimeConfigToast = true
        }

        runtimeConfigToastDismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.3)) {
                    showRuntimeConfigToast = false
                }
            }
        }
    }

    private var supportedRuntimeModeOptions: [RuntimePermissionMode] {
        if isOpenCodeSession {
            return []
        }

        if !runtimeSupportedPermissionModes.isEmpty {
            return runtimeSupportedPermissionModes
        }

        if isClaudeSession {
            return [.defaultMode, .acceptEdits, .plan, .dontAsk, .bypassPermissions]
        }
        if isCodexSession {
            return [.readOnly, .defaultMode, .fullAccess]
        }
        return [.safeYolo, .yolo]
    }

    private var contextGoToggleButton: some View {
        Button {
            toggleContextGoLink()
        } label: {
            HStack(spacing: 6) {
                Image("AppLogoSmall")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .opacity(isContextGoLinked ? 1.0 : 0.4)
                    .saturation(isContextGoLinked ? 1.0 : 0.0)

                if isContextGoLinked {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isContextGoLinked ? Color.green.opacity(0.12) : Color(.systemGray5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isContextGoLinked ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func sendCurrentMessage() {
        let selectedSkillContext = resolveSelectedSkillContextForOutgoingMessage()
        isInputFocused = false
        ensureDefaultLinkedSpaceIfNeeded()
        viewModel.sendMessage(
            contextGoLinked: isContextGoLinked,
            contextGoSpaceIds: Array(connectedSpaceIds),
            skillAutoLoad: isContextGoLinked,
            skillIntent: selectedSkillContext?.name,
            skillSpaceIds: Array(connectedSpaceIds),
            skillPinnedUris: selectedSkillContext.map { [$0.uri] } ?? loadedSkillUris,
            selectedSkillUri: selectedSkillContext?.uri,
            selectedSkillName: selectedSkillContext?.name
        )
        composerSelectedSkillUri = nil
        composerSelectedSkillName = nil
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            await syncRuntimeModeFromServer()
        }
    }

    private var slashSkillQuery: String? {
        let trimmed = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var showsSkillSlashPalette: Bool {
        slashSkillQuery != nil && !selectableSessionSkills.isEmpty
    }

    private var selectableSessionSkills: [CLISession.Metadata.Runtime.Skill] {
        sessionSkills.sorted { left, right in
            if isSystemSkill(left) != isSystemSkill(right) {
                return isSystemSkill(left)
            }
            return skillDisplayName(left).localizedCaseInsensitiveCompare(skillDisplayName(right)) == .orderedAscending
        }
    }

    private var filteredSlashSkills: [CLISession.Metadata.Runtime.Skill] {
        guard let query = slashSkillQuery else { return [] }
        if query.isEmpty {
            return selectableSessionSkills
        }

        let lowercasedQuery = query.lowercased()
        return selectableSessionSkills.filter { skill in
            let name = skillDisplayName(skill).lowercased()
            let uri = skill.skillUri.lowercased()
            let description = (skill.description ?? "").lowercased()
            return name.contains(lowercasedQuery)
                || uri.contains(lowercasedQuery)
                || description.contains(lowercasedQuery)
        }
    }

    private func skillDisplayName(_ skill: CLISession.Metadata.Runtime.Skill) -> String {
        if let name = skill.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return skill.skillUri
    }

    private func isSystemSkill(_ skill: CLISession.Metadata.Runtime.Skill) -> Bool {
        if let explicit = skill.isSystem {
            return explicit
        }
        return skill.skillUri.lowercased().hasSuffix("/skill_creator")
    }

    private func selectSkillFromSlash(_ skill: CLISession.Metadata.Runtime.Skill) {
        let displayName = skillDisplayName(skill)
        composerSelectedSkillUri = skill.skillUri
        composerSelectedSkillName = displayName
        viewModel.inputText = ""
        isInputFocused = true
    }

    private func resolveSelectedSkillContextForOutgoingMessage() -> (name: String, uri: String)? {
        guard let skillUri = composerSelectedSkillUri?.trimmingCharacters(in: .whitespacesAndNewlines),
              !skillUri.isEmpty else {
            let trimmed = viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("$") else { return nil }
            let rawName = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawName.isEmpty else { return nil }
            if let matched = selectableSessionSkills.first(where: { skillDisplayName($0).caseInsensitiveCompare(rawName) == .orderedSame }) {
                return (skillDisplayName(matched), matched.skillUri)
            }
            return nil
        }
        let name = composerSelectedSkillName?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let name, !name.isEmpty {
            return (name, skillUri)
        }
        if let matched = sessionSkills.first(where: { $0.skillUri == skillUri }) {
            let displayName = skillDisplayName(matched)
            return (displayName, skillUri)
        }
        return ("Selected Skill", skillUri)
    }

    private func handleComposerInputChange(oldValue _: String, newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("/") {
            composerSelectedSkillUri = nil
            composerSelectedSkillName = nil
            return
        }

        // Normal plain-text drafting should keep current selected skill.
        guard trimmed.hasPrefix("$") else { return }

        if let selectedName = composerSelectedSkillName,
           !trimmed.hasPrefix("$\(selectedName)") {
            composerSelectedSkillUri = nil
            composerSelectedSkillName = nil
        }
    }

    private func toggleContextGoLink() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            isContextGoLinked.toggle()
            if !isContextGoLinked {
                connectedSpaceIds.removeAll()
            } else if connectedSpaceIds.isEmpty, let firstSpace = availableSpaces.first {
                connectedSpaceIds = [firstSpace.id]
            }
        }
    }

    private func handleDisappear() {
        if viewModel.isHoldingSpeakButton {
            viewModel.cancelHoldToSpeakRecording()
        }
    }

    private func initializeSessionView() async {
        loadContextGoLinkedState()
        loadContextGoSpaces()
        await loadAvailableSpaces()
        ensureDefaultLinkedSpaceIfNeeded()
        client.connect()
        await refreshSessionSnapshotFromRemote()
        refreshSkillStateFromRuntime(sessionSnapshot.metadata?.runtime)
        await syncRuntimeModeFromServer()
        await refreshSkillsFromServer()
        if viewModel.messages.isEmpty {
            // Local cache missing: perform an immediate remote pull.
            await viewModel.syncMessagesFromRemote(forceFull: false)
        } else {
            // Local cache exists: keep UI responsive and sync in background.
            Task {
                await viewModel.syncMessagesFromRemote(forceFull: false)
            }
        }
    }

    @ViewBuilder
    private var messagesScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(spacing: 16) {
                        if shouldShowHistoryLoadMoreSentinel {
                            historyLoadMoreSentinel
                        }

                        CLIRenderedRunGroupList(
                            version: renderedRunGroupsVersion,
                            groups: visibleRenderedRunGroups,
                            providerFlavor: renderProviderFlavor,
                            hasActiveRun: viewModel.hasActiveRun,
                            permissionActionInFlight: viewModel.permissionActionInFlight,
                            onAllowPermission: { permissionId in
                                Task { await viewModel.allowPermission(permissionId) }
                            },
                            onAllowPermissionForSession: { permissionId in
                                Task { await viewModel.allowPermission(permissionId, forSession: true) }
                            },
                            onDenyPermission: { permissionId in
                                Task { await viewModel.denyPermission(permissionId, abort: false) }
                            }
                        )
                        .equatable()
                    }

                    Color.clear
                        .frame(height: 1)
                        .id(bottomScrollAnchorId)
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: BottomAnchorMaxYPreferenceKey.self,
                                    value: geometry.frame(in: .named(messagesScrollSpaceName)).maxY
                                )
                            }
                        )
                }
                .padding(.vertical, 12)
            }
            .coordinateSpace(name: messagesScrollSpaceName)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ScrollViewportHeightPreferenceKey.self,
                        value: geometry.size.height
                    )
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                isInputFocused = false
            }
            .onPreferenceChange(BottomAnchorMaxYPreferenceKey.self) { value in
                if abs(bottomAnchorMaxY - value) > 0.5 {
                    bottomAnchorMaxY = value
                }
                updateBottomAnchorVisibility(anchorMaxY: value)
            }
            .onPreferenceChange(ScrollViewportHeightPreferenceKey.self) { value in
                if abs(scrollViewportHeight - value) > 0.5 {
                    scrollViewportHeight = value
                    updateBottomAnchorVisibility(anchorMaxY: bottomAnchorMaxY)
                }
            }
            .onChange(of: renderedRunGroups.last?.id) { _, lastGroupId in
                guard lastGroupId != nil else { return }
                guard !viewModel.isLoadingOlderLocalMessages else { return }

                let shouldAutoScroll = !hasPerformedInitialAutoScroll
                    || (viewModel.hasActiveRun && isBottomAnchorVisible)
                guard shouldAutoScroll else { return }

                performAutoScroll(
                    proxy,
                    animated: !hasPerformedInitialAutoScroll,
                    throttled: false
                )
                hasPerformedInitialAutoScroll = true
            }
            .onChange(of: renderedRunGroupsVersion) { _, _ in
                guard renderedRunGroups.last != nil else { return }
                guard !viewModel.isLoadingOlderLocalMessages else { return }
                guard viewModel.hasActiveRun else { return }
                guard isBottomAnchorVisible else { return }

                // Keep following incremental agent updates inside the same run group.
                performAutoScroll(proxy, animated: false, throttled: true)
                hasPerformedInitialAutoScroll = true
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

    private var historyLoadMoreSentinel: some View {
        HStack(spacing: 8) {
            if canRevealOlderRenderedRunGroups {
                Image(systemName: "tray.2.fill")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else if viewModel.isLoadingOlderLocalMessages {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Text(historyLoadMoreText)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .task(id: historyPaginationTriggerID) {
            await requestOlderLocalHistoryIfNeeded()
        }
    }

    private var historyPaginationTriggerID: String {
        "\(viewModel.messages.first?.id ?? "none")|\(viewModel.canLoadOlderLocalMessages ? 1 : 0)|\(viewModel.isLoadingOlderLocalMessages ? 1 : 0)|\(visibleRunGroupLimit)|\(renderedRunGroups.count)"
    }

    private func requestOlderLocalHistoryIfNeeded() async {
        if canRevealOlderRenderedRunGroups {
            visibleRunGroupLimit = min(
                renderedRunGroups.count,
                visibleRunGroupLimit + runGroupPageSize
            )
            return
        }
        guard viewModel.canLoadOlderLocalMessages else { return }
        await viewModel.loadOlderLocalMessagesIfNeeded()
    }

    private var shouldShowScrollToBottomButton: Bool {
        !visibleRenderedRunGroups.isEmpty && !isBottomAnchorVisible
    }

    private var visibleRenderedRunGroups: [CLIRunGroup] {
        guard visibleRunGroupLimit > 0 else { return [] }
        guard renderedRunGroups.count > visibleRunGroupLimit else { return renderedRunGroups }
        return Array(renderedRunGroups.suffix(visibleRunGroupLimit))
    }

    private var canRevealOlderRenderedRunGroups: Bool {
        renderedRunGroups.count > visibleRunGroupLimit
    }

    private var shouldShowHistoryLoadMoreSentinel: Bool {
        canRevealOlderRenderedRunGroups || viewModel.canLoadOlderLocalMessages
    }

    private var historyLoadMoreText: String {
        if canRevealOlderRenderedRunGroups {
            return "上滑继续展开更早对话"
        }
        return viewModel.isLoadingOlderLocalMessages ? "正在加载更早消息…" : "上滑继续加载更早消息"
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

    private func loadContextGoLinkedState() {
        if UserDefaults.standard.object(forKey: contextGoLinkedKey) == nil {
            isContextGoLinked = true
            return
        }
        isContextGoLinked = UserDefaults.standard.bool(forKey: contextGoLinkedKey)
    }

    private func loadContextGoSpaces() {
        let ids = UserDefaults.standard.stringArray(forKey: contextGoSpacesKey) ?? []
        connectedSpaceIds = Set(ids)
    }

    private func loadAvailableSpaces() async {
        do {
            availableSpaces = try await SpaceService.shared.fetchSpaces()
            let validSpaceIds = Set(availableSpaces.map(\.id))
            connectedSpaceIds = Set(connectedSpaceIds.filter { validSpaceIds.contains($0) })
        } catch {
            print("⚠️ [SessionDetailView] Failed to load spaces: \(error)")
        }
    }

    private func ensureDefaultLinkedSpaceIfNeeded() {
        guard isContextGoLinked else { return }
        guard connectedSpaceIds.isEmpty else { return }
        guard let firstSpaceId = availableSpaces.first?.id, !firstSpaceId.isEmpty else { return }
        connectedSpaceIds = [firstSpaceId]
    }

    private func refreshSessionSnapshotFromRemote() async {
        do {
            if let remote = try await client.fetchSession(sessionId: session.id) {
                let preservedCustomTitle = liveTitleOverride?
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if let preservedCustomTitle, !preservedCustomTitle.isEmpty {
                    sessionSnapshot = applyingCustomTitle(preservedCustomTitle, to: remote)
                    liveTitleOverride = preservedCustomTitle
                } else {
                    sessionSnapshot = remote
                    liveTitleOverride = nil
                }
                viewModel.refreshBootstrapAgentState(
                    remote.agentState,
                    version: remote.agentStateVersion
                )
                refreshSkillStateFromRuntime(sessionSnapshot.metadata?.runtime)
                refreshSkillStateFromRuntime(sessionSnapshot.metadata?.runtime)
            }
        } catch {
            print("⚠️ [SessionDetailView] Failed to refresh session metadata from server: \(error)")
        }
    }

    private func handleSessionUpdatedNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let botId = userInfo["botId"] as? String,
              botId == client.ownerAgentId,
              let sessionId = userInfo["sessionId"] as? String,
              sessionId == session.id else {
            return
        }

        let hasMetadataUpdate = userInfo["hasMetadataUpdate"] as? Bool ?? false
        let hasAgentStateUpdate = userInfo["hasAgentStateUpdate"] as? Bool ?? false
        guard hasMetadataUpdate || hasAgentStateUpdate else { return }

        if hasAgentStateUpdate {
            viewModel.applyAuthoritativeSessionStatus(
                statusRaw: userInfo["agentStateStatus"] as? String,
                version: userInfo["agentStateVersion"] as? Int
            )
        }

        if hasMetadataUpdate,
           let displayName = userInfo["displayName"] as? String,
           !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            liveTitleOverride = displayName
        }

        Task {
            if hasMetadataUpdate {
                await refreshSessionSnapshotFromRemote()
                return
            }

            // Agent-state-only update (e.g. permission approved/denied) should
            // still force a lightweight sync; otherwise pending cards can linger.
            await viewModel.syncMessagesFromRemote(forceFull: false)
        }
    }

    private func handleBack() {
        if let onDismiss {
            onDismiss()
        } else {
            dismiss()
        }
    }

    private var currentDisplayTitle: String {
        let overrideTitle = liveTitleOverride?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let overrideTitle, !overrideTitle.isEmpty {
            return overrideTitle
        }
        return sessionSnapshot.displayName
    }

    private func openTitleRenameSheet() {
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
        pendingTitleInput = currentDisplayTitle
        showTitleRenameSheet = true
    }

    private func persistCustomTitle() {
        let trimmed = pendingTitleInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        showTitleRenameSheet = false

        Task {
            do {
                var localSession = try await resolveLocalContextSessionForRename()
                localSession.title = trimmed
                localSession.updatedAt = Date()

                var metadata = localSession.channelMetadataDict ?? [:]
                metadata["customTitle"] = trimmed

                if let rawJSON = metadata["rawJSON"] as? String,
                   var rawObject = parseJSONObject(rawJSON) {
                    rawObject["customTitle"] = trimmed
                    if let encodedRaw = encodeJSONObject(rawObject) {
                        metadata["rawJSON"] = encodedRaw
                    }
                }

                localSession.setChannelMetadata(metadata)
                try await sessionRepository.updateSession(localSession, notifyCloud: false)

                await MainActor.run {
                    sessionSnapshot = applyingCustomTitle(trimmed, to: sessionSnapshot)
                    liveTitleOverride = trimmed

                    NotificationCenter.default.post(
                        name: NSNotification.Name("CLISessionUpdated"),
                        object: nil,
                        userInfo: [
                            "botId": client.ownerAgentId,
                            "sessionId": session.id,
                            "hasMetadataUpdate": true,
                            "displayName": trimmed
                        ]
                    )

                    NotificationCenter.default.post(
                        name: NSNotification.Name("ContextGoSessionUpdated"),
                        object: nil,
                        userInfo: [
                            "sessionId": localSession.id,
                            "agentId": localSession.agentId,
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

    private func resolveLocalContextSessionForRename() async throws -> ContextGoSession {
        if let local = try await sessionRepository.getSession(id: session.id) {
            return local
        }

        let allSessions = try await sessionRepository.getAllSessionsIncludingArchived(agentId: client.ownerAgentId)
        if let matched = allSessions.first(where: { $0.cliSessionId == session.id }) {
            return matched
        }

        throw NSError(
            domain: "SessionDetailView",
            code: 404,
            userInfo: [NSLocalizedDescriptionKey: "未找到本地会话记录"]
        )
    }

    private func applyingCustomTitle(_ title: String, to source: CLISession) -> CLISession {
        guard let metadata = source.metadata else { return source }

        var updated = source
        updated.metadata = CLISession.Metadata(
            path: metadata.path,
            host: metadata.host,
            machineId: metadata.machineId,
            hostPid: metadata.hostPid,
            flavor: metadata.flavor,
            homeDir: metadata.homeDir,
            version: metadata.version,
            platform: metadata.platform,
            runtime: metadata.runtime,
            claudeSessionId: metadata.claudeSessionId,
            codexSessionId: metadata.codexSessionId,
            opencodeSessionId: metadata.opencodeSessionId,
            geminiSessionId: metadata.geminiSessionId,
            customTitle: title,
            summary: metadata.summary,
            gitStatus: metadata.gitStatus
        )
        return updated
    }

    private func parseJSONObject(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func encodeJSONObject(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let json = String(data: data, encoding: .utf8) else {
            return nil
        }
        return json
    }

    private func parseInt(_ raw: Any?) -> Int? {
        if let value = raw as? Int { return value }
        if let value = raw as? Double { return Int(value) }
        if let value = raw as? NSNumber { return value.intValue }
        if let value = raw as? String { return Int(value) }
        return nil
    }

    private func parseDate(_ raw: Any?) -> Date? {
        if let date = raw as? Date {
            return date
        }
        if let number = raw as? NSNumber {
            let value = number.doubleValue
            return value > 1_000_000_000_000
                ? Date(timeIntervalSince1970: value / 1000.0)
                : Date(timeIntervalSince1970: value)
        }
        if let value = raw as? Double {
            return value > 1_000_000_000_000
                ? Date(timeIntervalSince1970: value / 1000.0)
                : Date(timeIntervalSince1970: value)
        }
        if let value = raw as? Int {
            let asDouble = Double(value)
            return asDouble > 1_000_000_000_000
                ? Date(timeIntervalSince1970: asDouble / 1000.0)
                : Date(timeIntervalSince1970: asDouble)
        }
        if let text = raw as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty { return nil }
            let formatter = ISO8601DateFormatter()
            if let parsed = formatter.date(from: normalized) {
                return parsed
            }
            if let seconds = Double(normalized) {
                return seconds > 1_000_000_000_000
                    ? Date(timeIntervalSince1970: seconds / 1000.0)
                    : Date(timeIntervalSince1970: seconds)
            }
        }
        return nil
    }

    private func parseStringList(_ raw: Any?) -> [String] {
        guard let items = raw as? [Any] else { return [] }
        return items.compactMap { item in
            guard let text = item as? String else { return nil }
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private func normalizeStringList(_ items: [String]) -> [String] {
        var results: [String] = []
        var seen = Set<String>()
        for item in items {
            let normalized = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                results.append(normalized)
            }
        }
        return results
    }

    private func parseDictionary(_ raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] {
            return dict
        }
        if let bridged = raw as? [AnyHashable: Any] {
            return Dictionary(uniqueKeysWithValues: bridged.compactMap { entry in
                guard let key = entry.key as? String else { return nil }
                return (key, entry.value)
            })
        }
        return nil
    }

    private func parseSkillString(_ raw: Any?) -> String? {
        if let text = raw as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
        if let dict = parseDictionary(raw) {
            return firstNonEmptySkillString([
                dict["text"],
                dict["value"],
                dict["name"],
                dict["title"],
                dict["description"],
                dict["summary"]
            ])
        }
        return nil
    }

    private func firstNonEmptySkillString(_ candidates: [Any?]) -> String? {
        for candidate in candidates {
            if let value = parseSkillString(candidate) {
                return value
            }
        }
        return nil
    }

    private func parseRuntimeSkill(_ raw: Any?) -> CLISession.Metadata.Runtime.Skill? {
        guard let value = raw as? [String: Any] else { return nil }
        let nested = parseDictionary(value["skill"])
            ?? parseDictionary(value["metadata"])
            ?? parseDictionary(value["data"])
        let skillUri = firstNonEmptySkillString([
            value["skillUri"],
            value["skillURI"],
            value["skill_uri"],
            value["uri"],
            nested?["skillUri"],
            nested?["skillURI"],
            nested?["skill_uri"],
            nested?["uri"]
        ])
        guard let skillUri, !skillUri.isEmpty else { return nil }

        let name = firstNonEmptySkillString([
            value["name"],
            value["displayName"],
            value["skillName"],
            value["title"],
            nested?["name"],
            nested?["displayName"],
            nested?["skillName"],
            nested?["title"]
        ])
        let description = firstNonEmptySkillString([
            value["description"],
            value["desc"],
            value["summary"],
            value["detail"],
            value["promptTemplate"],
            nested?["description"],
            nested?["desc"],
            nested?["summary"],
            nested?["detail"],
            nested?["promptTemplate"]
        ])
        let scope = firstNonEmptySkillString([
            value["scope"],
            nested?["scope"]
        ])
        let type = firstNonEmptySkillString([
            value["type"],
            nested?["type"]
        ])
        let spaceId = firstNonEmptySkillString([
            value["spaceId"],
            value["spaceID"],
            nested?["spaceId"],
            nested?["spaceID"]
        ])

        return CLISession.Metadata.Runtime.Skill(
            skillUri: skillUri,
            name: (name?.isEmpty == false) ? name : nil,
            description: (description?.isEmpty == false) ? description : nil,
            scope: (scope?.isEmpty == false) ? scope : nil,
            type: (type?.isEmpty == false) ? type : nil,
            spaceId: (spaceId?.isEmpty == false) ? spaceId : nil,
            isSystem: parseBool(value["isSystem"]) ?? parseBool(nested?["isSystem"]),
            isLoaded: value["isLoaded"] as? Bool,
            lastLoadedAt: parseDate(value["lastLoadedAt"])
        )
    }

    private func parseRuntimeSkills(_ raw: Any?) -> [CLISession.Metadata.Runtime.Skill]? {
        guard let items = raw as? [Any] else { return nil }
        let parsed = items.compactMap(parseRuntimeSkill)
        return parsed.isEmpty ? nil : parsed
    }

    private func parseBool(_ raw: Any?) -> Bool? {
        if let value = raw as? Bool {
            return value
        }
        if let value = raw as? NSNumber {
            return value.boolValue
        }
        if let value = raw as? String {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) {
                return true
            }
            if ["false", "0", "no", "n"].contains(normalized) {
                return false
            }
        }
        return nil
    }

    private func isLikelyOpenCodeModeId(_ raw: String) -> Bool {
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.count <= 160 else { return false }
        guard !normalized.contains("/"), !normalized.contains("\\") else { return false }
        // OpenCode mode can be a human-readable name like "Sisyphus (Ultraworker)".
        // Reject only control characters.
        return normalized.range(of: #"[\u{0000}-\u{001F}\u{007F}]"#, options: .regularExpression) == nil
    }

    private func parseOpenCodeModeOptions(_ raw: Any?) -> [OpenCodeModeOption] {
        guard let items = raw as? [Any] else { return [] }
        return items.compactMap { item in
            if let direct = item as? String {
                let normalized = direct.trimmingCharacters(in: .whitespacesAndNewlines)
                guard isLikelyOpenCodeModeId(normalized) else { return nil }
                return OpenCodeModeOption(id: normalized, name: normalized, description: nil)
            }

            let record: [String: Any]
            if let direct = item as? [String: Any] {
                record = direct
            } else if let bridged = item as? [AnyHashable: Any] {
                record = Dictionary(uniqueKeysWithValues: bridged.compactMap { entry in
                    guard let stringKey = entry.key as? String else { return nil }
                    return (stringKey, entry.value)
                })
            } else {
                return nil
            }

            let id = (record["id"] as? String)
                ?? (record["modeId"] as? String)
                ?? (record["currentModeId"] as? String)
            let name = (record["name"] as? String)
                ?? (record["label"] as? String)
                ?? (record["title"] as? String)
                ?? id

            guard let id,
                  let name else {
                return nil
            }
            let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isLikelyOpenCodeModeId(normalizedId), !normalizedName.isEmpty else { return nil }
            return OpenCodeModeOption(
                id: normalizedId,
                name: normalizedName,
                description: (record["description"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private func normalizeOpenCodeVariantValue(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }
        if normalized.lowercased() == OpenCodeVariantOption.defaultValue {
            return nil
        }
        return normalized
    }

    private func normalizeOpenCodeVariantList(_ values: [String]) -> [String] {
        var results: [String] = []
        var seen = Set<String>()

        for item in values {
            guard let normalized = normalizeOpenCodeVariantValue(item) else { continue }
            let key = normalized.lowercased()
            if seen.insert(key).inserted {
                results.append(normalized)
            }
        }

        return results
    }

    private func rebuildRunGroups(from messages: [CLIMessage]) {
        runGroupBuildGeneration += 1
        let generation = runGroupBuildGeneration
        let snapshot = messages
        let snapshotMessageIDs = snapshot.map(\.id)
        let previousMessageIDs = lastRenderedMessageIDs
        let previousGroups = renderedRunGroups
        let canApplyIncrementalAppend = !previousGroups.isEmpty
            && snapshotMessageIDs.count > previousMessageIDs.count
            && snapshotMessageIDs.starts(with: previousMessageIDs)
        let canApplyIncrementalRefresh = !previousGroups.isEmpty
            && snapshotMessageIDs.count == previousMessageIDs.count
            && snapshotMessageIDs.elementsEqual(previousMessageIDs)
        let appendedMessages = canApplyIncrementalAppend
            ? Array(snapshot.suffix(snapshotMessageIDs.count - previousMessageIDs.count))
            : []
        let providerFlavorSnapshot = renderProviderFlavor

        runGroupBuildTask?.cancel()
        runGroupBuildTask = Task(priority: .utility) {
            let groups = await Task.detached(priority: .utility) {
                if canApplyIncrementalAppend {
                    return CLIRunGrouper.append(
                        existing: previousGroups,
                        with: appendedMessages,
                        providerFlavor: providerFlavorSnapshot
                    )
                }
                if canApplyIncrementalRefresh {
                    return CLIRunGrouper.refresh(
                        existing: previousGroups,
                        with: snapshot,
                        providerFlavor: providerFlavorSnapshot
                    )
                }
                return CLIRunGrouper.build(
                    from: snapshot,
                    providerFlavor: providerFlavorSnapshot
                )
            }.value

            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard generation == runGroupBuildGeneration else { return }
                renderedRunGroups = groups
                renderedRunGroupsVersion &+= 1
                lastRenderedMessageIDs = snapshotMessageIDs
            }
        }
    }

    private func refreshSkillStateFromRuntime(_ runtime: CLISession.Metadata.Runtime?) {
        guard let runtime else { return }
        if let runtimeMcpTools = runtime.mcpToolNames {
            mcpToolNames = runtimeMcpTools
        }
        if let available = runtime.skillAvailableCount {
            skillAvailableCount = available
        }
        if let loaded = runtime.skillLoadedCount {
            skillLoadedCount = loaded
        }
        if let loadedUris = runtime.skillLoadedUris {
            loadedSkillUris = loadedUris
        }
        if let loadState = runtime.skillLoadState,
           !loadState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            skillLoadState = loadState
        }
        if let syncAt = runtime.skillLastSyncAt {
            skillLastSyncAt = syncAt
        }
        if let lastError = runtime.skillLastError {
            skillLastError = lastError
        }
        if let runtimeSkills = runtime.skills {
            sessionSkills = mergeSkills(current: sessionSkills, incoming: runtimeSkills)
        }
    }

    private func refreshSkillsFromServer() async {
        guard runtimeConfigAvailable else { return }
        guard !isSkillListRefreshing else { return }

        isSkillListRefreshing = true
        skillActionError = nil
        defer { isSkillListRefreshing = false }

        do {
            let spaceIds = Array(connectedSpaceIds).sorted()
            var scopedUris: [String?] = [nil]
            for spaceId in spaceIds {
                let uri = spaceRootURI(for: spaceId)
                if !scopedUris.contains(where: { $0 == uri }) {
                    scopedUris.append(uri)
                }
            }

            var merged: [CLISession.Metadata.Runtime.Skill] = []
            var seen = Set<String>()
            var partialErrors: [String] = []

            for scopeUri in scopedUris {
                let list: [CLISession.Metadata.Runtime.Skill]
                do {
                    list = try await client.listSessionSkills(
                        for: session.id,
                        spaceUri: scopeUri
                    )
                } catch {
                    let scopeLabel = scopeUri ?? "global"
                    partialErrors.append("\(scopeLabel): \(error.localizedDescription)")
                    continue
                }
                for skill in list {
                    if seen.contains(skill.skillUri) {
                        continue
                    }
                    seen.insert(skill.skillUri)
                    merged.append(skill)
                }
            }

            sessionSkills = mergeSkills(current: sessionSkills, incoming: merged)
            skillAvailableCount = merged.count
            if merged.isEmpty, !partialErrors.isEmpty {
                skillActionError = "刷新技能失败: \(partialErrors.joined(separator: " | "))"
            }
            if !loadedSkillUris.isEmpty {
                sessionSkills = sessionSkills.map { skill in
                    CLISession.Metadata.Runtime.Skill(
                        skillUri: skill.skillUri,
                        name: skill.name,
                        description: skill.description,
                        scope: skill.scope,
                        type: skill.type,
                        spaceId: skill.spaceId,
                        isSystem: skill.isSystem,
                        isLoaded: loadedSkillUris.contains(skill.skillUri) || (skill.isLoaded ?? false),
                        lastLoadedAt: skill.lastLoadedAt
                    )
                }
            }
            await syncRuntimeModeFromServer()
        } catch {
            skillActionError = "刷新技能失败: \(error.localizedDescription)"
        }
    }

    private func spaceRootURI(for spaceId: String) -> String {
        let encoded = spaceId.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? spaceId
        return "ctxgo://\(encoded)/space/root"
    }

    private func mergeSkills(
        current: [CLISession.Metadata.Runtime.Skill],
        incoming: [CLISession.Metadata.Runtime.Skill]
    ) -> [CLISession.Metadata.Runtime.Skill] {
        var map: [String: CLISession.Metadata.Runtime.Skill] = [:]

        for skill in current {
            map[skill.skillUri] = skill
        }

        for skill in incoming {
            if let existing = map[skill.skillUri] {
                map[skill.skillUri] = CLISession.Metadata.Runtime.Skill(
                    skillUri: skill.skillUri,
                    name: skill.name ?? existing.name,
                    description: skill.description ?? existing.description,
                    scope: skill.scope ?? existing.scope,
                    type: skill.type ?? existing.type,
                    spaceId: skill.spaceId ?? existing.spaceId,
                    isSystem: skill.isSystem ?? existing.isSystem,
                    isLoaded: (skill.isLoaded ?? false) || (existing.isLoaded ?? false),
                    lastLoadedAt: skill.lastLoadedAt ?? existing.lastLoadedAt
                )
            } else {
                map[skill.skillUri] = skill
            }
        }

        return map.values.sorted { lhs, rhs in
            if isSystemSkill(lhs) != isSystemSkill(rhs) {
                return isSystemSkill(lhs)
            }
            let left = (lhs.name?.isEmpty == false) ? lhs.name! : lhs.skillUri
            let right = (rhs.name?.isEmpty == false) ? rhs.name! : rhs.skillUri
            return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
        }
    }

    private func syncRuntimeModeFromServer() async {
        guard runtimeConfigAvailable else { return }
        do {
            let runtimeConfig = try await client.getRuntimeConfig(for: session.id)
            let permissionMode = (runtimeConfig["permissionMode"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let supportedPermissionModes = normalizeStringList(parseStringList(runtimeConfig["supportedPermissionModes"]))
            let mappedMode = RuntimePermissionMode.fromRuntimePermission(
                permissionMode,
                supportsClaudeExtendedModes: isClaudeSession,
                preferCodexPermissionNaming: isCodexSession
            )
            let controlMode = RuntimeControlMode.fromRuntimeMode(runtimeConfig["mode"] as? String)
            let runtimeModel = runtimeConfig["model"] as? String
            let runtimeReasoning = runtimeConfig["reasoningEffort"] as? String
            let supportedReasoning = runtimeConfig["supportedReasoningEfforts"] as? [String]

            if runtimeMode != mappedMode {
                runtimeMode = mappedMode
                print("✅ [SessionDetailView] Synced runtime mode from server: \(runtimePermissionModeDisplayName(mappedMode))")
            }
            if runtimeControlMode != controlMode {
                runtimeControlMode = controlMode
                print("✅ [SessionDetailView] Synced control mode from server: \(controlMode.rawValue)")
            }
            if let runtimeModel,
               !runtimeModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                runtimeModelDisplay = runtimeModel
            } else if runtimeModelDisplay == nil {
                runtimeModelDisplay = sessionSnapshot.metadata?.runtime?.model
            }
            runtimePermissionModeId = permissionMode
            if !isOpenCodeSession {
                runtimeSupportedPermissionModeIds = supportedPermissionModes
                let mappedSupportedModes = RuntimePermissionMode.fromRuntimePermissionList(
                    supportedPermissionModes,
                    supportsClaudeExtendedModes: isClaudeSession,
                    preferCodexPermissionNaming: isCodexSession
                )
                if !mappedSupportedModes.isEmpty {
                    runtimeSupportedPermissionModes = mappedSupportedModes
                }
                if !runtimeSupportedPermissionModes.isEmpty,
                   !runtimeSupportedPermissionModes.contains(runtimeMode),
                   let firstMode = runtimeSupportedPermissionModes.first {
                    runtimeMode = firstMode
                }
            } else {
                runtimeSupportedPermissionModeIds = []
            }
            if isCodexSession {
                if let mappedReasoning = CodexReasoningEffortOption.from(raw: runtimeReasoning) {
                    runtimeReasoningEffort = mappedReasoning
                }
                let mappedSupported = CodexReasoningEffortOption.from(rawList: supportedReasoning)
                runtimeSupportedReasoningEfforts = mappedSupported.isEmpty
                    ? CodexReasoningEffortOption.defaultOptions
                    : mappedSupported
                if !runtimeSupportedReasoningEfforts.contains(runtimeReasoningEffort) {
                    runtimeReasoningEffort = runtimeSupportedReasoningEfforts.first ?? .medium
                }
            }

            if isOpenCodeSession {
                let runtimeModeId = (runtimeConfig["opencodeModeId"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if let runtimeModeId, !runtimeModeId.isEmpty {
                    opencodeModeId = runtimeModeId
                }

                let availableModes = parseOpenCodeModeOptions(runtimeConfig["opencodeAvailableModes"])
                if runtimeConfig.keys.contains("opencodeAvailableModes") {
                    opencodeAvailableModes = availableModes
                }

                let currentModelId = (runtimeConfig["opencodeModelId"] as? String)
                    ?? (runtimeConfig["opencodeCurrentModelId"] as? String)
                    ?? runtimeModel
                if let currentModelId,
                   !currentModelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    opencodeModelId = currentModelId
                }

                let runtimeVariant = (runtimeConfig["opencodeVariant"] as? String) ?? runtimeReasoning
                opencodeVariant = normalizeOpenCodeVariantValue(runtimeVariant)

                let availableVariants = normalizeOpenCodeVariantList(parseStringList(
                    runtimeConfig["opencodeAvailableVariants"]
                ))
                let fallbackVariants = normalizeOpenCodeVariantList(parseStringList(
                    runtimeConfig["supportedReasoningEfforts"]
                ))
                if runtimeConfig.keys.contains("opencodeAvailableVariants") {
                    opencodeAvailableVariants = availableVariants
                } else {
                    opencodeAvailableVariants = fallbackVariants
                }

                if let detected = parseBool(runtimeConfig["opencodeOhMyOpencodeDetected"]) {
                    opencodeOmoDetected = detected
                }
                if let registered = parseBool(runtimeConfig["opencodeOhMyOpencodeRegistered"]) {
                    opencodeOmoRegistered = registered
                }
                opencodeOmoEntry = (runtimeConfig["opencodeOhMyOpencodeEntry"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                opencodeOmoModeHints = parseStringList(runtimeConfig["opencodeOhMyOpencodeModeHints"])
            }

            if runtimeConfig.keys.contains("mcpToolNames") {
                mcpToolNames = parseStringList(runtimeConfig["mcpToolNames"])
            }
            if runtimeConfig.keys.contains("skillAvailableCount") {
                skillAvailableCount = parseInt(runtimeConfig["skillAvailableCount"]) ?? 0
            }
            if runtimeConfig.keys.contains("skillLoadedCount") {
                skillLoadedCount = parseInt(runtimeConfig["skillLoadedCount"]) ?? 0
            }
            if runtimeConfig.keys.contains("loadedSkillUris") || runtimeConfig.keys.contains("skillLoadedUris") {
                loadedSkillUris = parseStringList(runtimeConfig["loadedSkillUris"] ?? runtimeConfig["skillLoadedUris"])
            }
            if let state = runtimeConfig["skillLoadState"] as? String,
               !state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                skillLoadState = state
            }
            if runtimeConfig.keys.contains("skillLastSyncAt") {
                skillLastSyncAt = parseDate(runtimeConfig["skillLastSyncAt"])
            }
            if runtimeConfig.keys.contains("skillLastError") {
                skillLastError = runtimeConfig["skillLastError"] as? String
            }
            if runtimeConfig.keys.contains("skills"),
               let runtimeSkills = parseRuntimeSkills(runtimeConfig["skills"]) {
                sessionSkills = mergeSkills(current: sessionSkills, incoming: runtimeSkills)
            }
        } catch {
            if isRuntimeConfigUnavailableError(error) {
                runtimeConfigAvailable = false
                return
            }
            print("⚠️ [SessionDetailView] Failed to sync runtime mode: \(error)")
        }
    }

    private func updateRuntimePermissionMode(_ nextMode: RuntimePermissionMode) async {
        guard runtimeConfigAvailable else {
            runtimeModeUpdateError = "当前会话不支持运行模式配置"
            return
        }
        guard runtimeMode != nextMode else { return }
        guard !isRuntimeModeUpdating else { return }

        isRuntimeModeUpdating = true
        runtimeModeUpdateError = nil
        defer { isRuntimeModeUpdating = false }

        do {
            let permissionModeValue = runtimePermissionModeRequestValue(nextMode)
            _ = try await client.setRuntimeConfig(
                for: session.id,
                permissionMode: permissionModeValue
            )
            runtimeMode = nextMode
            runtimePermissionModeId = permissionModeValue
            showRuntimeToast("已切换模式为 \(runtimePermissionModeDisplayName(nextMode))")
            await syncRuntimeModeFromServer()
        } catch {
            runtimeModeUpdateError = "运行模式更新失败：\(error.localizedDescription)"
            await syncRuntimeModeFromServer()
        }
    }

    private func updateRuntimePermissionModeById(_ modeId: String) async {
        guard runtimeConfigAvailable else {
            runtimeModeUpdateError = "当前会话不支持运行模式配置"
            return
        }
        guard !isOpenCodeSession else { return }

        let normalizedModeId = modeId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedModeId.isEmpty else { return }
        guard runtimePermissionModeId != normalizedModeId else { return }
        guard !isRawRuntimeModeUpdating else { return }

        isRawRuntimeModeUpdating = true
        runtimeModeUpdateError = nil
        defer { isRawRuntimeModeUpdating = false }

        do {
            _ = try await client.setRuntimeConfig(
                for: session.id,
                permissionMode: normalizedModeId
            )
            runtimePermissionModeId = normalizedModeId
            runtimeMode = RuntimePermissionMode.fromRuntimePermission(
                normalizedModeId,
                supportsClaudeExtendedModes: isClaudeSession,
                preferCodexPermissionNaming: isCodexSession
            )
            showRuntimeToast("已切换为 \(normalizedModeId)")
            await syncRuntimeModeFromServer()
        } catch {
            runtimeModeUpdateError = "运行模式更新失败：\(error.localizedDescription)"
            await syncRuntimeModeFromServer()
        }
    }

    private func runtimePermissionModeDisplayName(_ mode: RuntimePermissionMode) -> String {
        mode.displayName(preferCodexPermissionNaming: isCodexSession)
    }

    private func runtimePermissionModeRequestValue(_ mode: RuntimePermissionMode) -> String {
        if isCodexSession {
            switch mode {
            case .readOnly:
                return "read-only"
            case .defaultMode, .safeYolo, .acceptEdits, .plan, .dontAsk:
                return "workspace-write"
            case .fullAccess, .yolo, .bypassPermissions:
                return "danger-full-access"
            }
        }
        return mode.rawValue
    }

    private func updateRuntimeReasoningEffort(_ effort: CodexReasoningEffortOption) async {
        guard supportsCodexReasoningControl else { return }
        guard !isRuntimeReasoningUpdating else { return }
        guard runtimeReasoningEffort != effort else { return }

        isRuntimeReasoningUpdating = true
        defer { isRuntimeReasoningUpdating = false }

        do {
            _ = try await client.setRuntimeConfig(
                for: session.id,
                reasoningEffort: effort.rawValue
            )
            runtimeReasoningEffort = effort
            showRuntimeToast("已切换思考级别为 \(effort.displayName)")
            await syncRuntimeModeFromServer()
        } catch {
            viewModel.errorMessage = "思考级别更新失败：\(error.localizedDescription)"
            viewModel.showError = true
            await syncRuntimeModeFromServer()
        }
    }

    private func updateOpenCodeMode(_ mode: OpenCodeModeOption) async {
        guard isOpenCodeSession else { return }
        guard runtimeConfigAvailable else { return }
        guard !isOpenCodeModeUpdating else { return }
        guard mode.id != opencodeModeId else { return }

        isOpenCodeModeUpdating = true
        defer { isOpenCodeModeUpdating = false }

        do {
            _ = try await client.setRuntimeConfig(
                for: session.id,
                modeId: mode.id
            )
            opencodeModeId = mode.id
            showRuntimeToast("已切换 OpenCode 模式为 \(mode.name)")
            await syncRuntimeModeFromServer()
        } catch {
            viewModel.errorMessage = "OpenCode 模式更新失败：\(error.localizedDescription)"
            viewModel.showError = true
            await syncRuntimeModeFromServer()
        }
    }

    private func updateOpenCodeVariant(_ variant: String?) async {
        guard isOpenCodeSession else { return }
        guard runtimeConfigAvailable else { return }
        guard !isOpenCodeVariantUpdating else { return }
        guard (opencodeVariant ?? OpenCodeVariantOption.defaultValue)
            != (variant ?? OpenCodeVariantOption.defaultValue) else { return }

        isOpenCodeVariantUpdating = true
        defer { isOpenCodeVariantUpdating = false }

        do {
            _ = try await client.setRuntimeConfig(
                for: session.id,
                modelId: opencodeModelId,
                variant: variant ?? OpenCodeVariantOption.defaultValue
            )
            opencodeVariant = variant
            showRuntimeToast("已切换 OpenCode 思考为 \(variant ?? OpenCodeVariantOption.defaultValue)")
            await syncRuntimeModeFromServer()
        } catch {
            viewModel.errorMessage = "OpenCode 思考模式更新失败：\(error.localizedDescription)"
            viewModel.showError = true
            await syncRuntimeModeFromServer()
        }
    }

    private func selectOpenCodeMode(_ mode: OpenCodeModeOption) async {
        let previousModeId = opencodeModeId
        await updateOpenCodeMode(mode)
        if opencodeModeId != previousModeId && opencodeModeId == mode.id {
            showOpenCodeModeSheet = false
        }
    }

    private func selectOpenCodeModeById(_ modeId: String) async {
        guard let mode = opencodeAvailableModes.first(where: { $0.id == modeId }) else {
            return
        }
        await selectOpenCodeMode(mode)
    }

    private func selectOpenCodeVariant(_ variant: String) async {
        let previousVariant = normalizedOpenCodeVariantSelection
        let resolvedVariant = variant == OpenCodeVariantOption.defaultValue ? nil : variant
        await updateOpenCodeVariant(resolvedVariant)
        if normalizedOpenCodeVariantSelection != previousVariant,
           normalizedOpenCodeVariantSelection == variant {
            showOpenCodeVariantSheet = false
        }
    }

    private func replayFromServerAfterClearingLocalCache() async {
        guard !isReplayRefreshing else { return }

        isReplayRefreshing = true
        replayRefreshError = nil
        defer { isReplayRefreshing = false }

        do {
            try await viewModel.resetLocalCacheAndReplayFromRemote()
            await refreshSessionSnapshotFromRemote()
            await syncRuntimeModeFromServer()
            rebuildRunGroups(from: viewModel.messages)
        } catch {
            replayRefreshError = "重新回放失败：\(error.localizedDescription)"
        }
    }

    private func isRuntimeConfigUnavailableError(_ error: Error) -> Bool {
        let lowered = error.localizedDescription.lowercased()
        return lowered.contains("rpc method not available")
            || lowered.contains("method not available")
            || lowered.contains("method not found")
    }
}

private struct OpenCodeModeOption: Identifiable, Hashable {
    let id: String
    let name: String
    let description: String?
}

private enum OpenCodeVariantOption {
    static let defaultValue = "default"
}

private enum CodexReasoningEffortOption: String, CaseIterable {
    case none
    case minimal
    case low
    case medium
    case high
    case xhigh

    static let defaultOptions: [CodexReasoningEffortOption] = [.low, .medium, .high, .xhigh]

    static func from(raw: String?) -> CodexReasoningEffortOption? {
        guard let raw else { return nil }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none", "off":
            return .none
        case "minimal", "min":
            return .minimal
        case "low":
            return .low
        case "medium", "med", "mid":
            return .medium
        case "high":
            return .high
        case "xhigh", "x-high", "extra-high", "extra_high":
            return .xhigh
        default:
            return nil
        }
    }

    static func from(rawList: [String]?) -> [CodexReasoningEffortOption] {
        guard let rawList, !rawList.isEmpty else { return [] }
        var seen = Set<String>()
        var resolved: [CodexReasoningEffortOption] = []
        for raw in rawList {
            guard let option = from(raw: raw) else { continue }
            if seen.insert(option.rawValue).inserted {
                resolved.append(option)
            }
        }
        return resolved
    }

    var displayName: String {
        switch self {
        case .none:
            return "关闭"
        case .minimal:
            return "极简"
        case .low:
            return "低"
        case .medium:
            return "中"
        case .high:
            return "高"
        case .xhigh:
            return "超高"
        }
    }

    var compactLabel: String {
        switch self {
        case .none:
            return "关"
        case .minimal:
            return "极简"
        case .low:
            return "低"
        case .medium:
            return "中"
        case .high:
            return "高"
        case .xhigh:
            return "超高"
        }
    }

    var dialogTitle: String {
        switch self {
        case .none:
            return "关闭（none）"
        case .minimal:
            return "极简（minimal）"
        case .low:
            return "低（low）"
        case .medium:
            return "中（medium）"
        case .high:
            return "高（high）"
        case .xhigh:
            return "超高（xhigh）"
        }
    }
}

private struct CLISkillSlashPaletteView: View {
    let skills: [CLISession.Metadata.Runtime.Skill]
    let onSelect: (CLISession.Metadata.Runtime.Skill) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var expandedSkillUris: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if skills.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                        Text("没有匹配到可用技能")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 14)
                    .padding(.horizontal, 14)
                } else {
                    ForEach(skills, id: \.skillUri) { skill in
                        let expanded = isExpanded(skill)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "bolt.horizontal.circle.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(.green)

                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(displayName(for: skill))
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundColor(.primary)
                                            .lineLimit(1)
                                        if isSystemSkill(skill) {
                                            Text("系统")
                                                .font(.system(size: 10, weight: .bold))
                                                .foregroundColor(.orange)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.14))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    if let description = descriptionText(for: skill) {
                                        Text(description)
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                            .lineLimit(expanded ? nil : 2)
                                    } else {
                                        Text("暂无描述")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                }

                                Spacer(minLength: 8)

                                Button {
                                    onSelect(skill)
                                } label: {
                                    Text("填入")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.blue)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(Color.blue.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onSelect(skill)
                            }

                            HStack(spacing: 8) {
                                if hasExpandableContent(skill) {
                                    Button {
                                        toggleExpanded(skill)
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(expanded ? "收起内容" : "展开内容")
                                                .font(.system(size: 11, weight: .medium))
                                            Image(systemName: expanded ? "chevron.up" : "chevron.down")
                                                .font(.system(size: 9, weight: .semibold))
                                        }
                                        .foregroundColor(.secondary)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer(minLength: 0)
                            }

                            if expanded {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Skill URI")
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundColor(.secondary)
                                    Text(skill.skillUri)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .background(Color.secondary.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)

                        if skill.skillUri != skills.last?.skillUri {
                            Divider()
                                .padding(.leading, 40)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: 320)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(colorScheme == .dark ? Color(white: 0.15) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(colorScheme == .dark ? Color(white: 0.3) : Color(white: 0.9), lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.12),
            radius: 10,
            x: 0,
            y: 4
        )
    }

    private func isExpanded(_ skill: CLISession.Metadata.Runtime.Skill) -> Bool {
        expandedSkillUris.contains(skill.skillUri)
    }

    private func toggleExpanded(_ skill: CLISession.Metadata.Runtime.Skill) {
        if expandedSkillUris.contains(skill.skillUri) {
            expandedSkillUris.remove(skill.skillUri)
        } else {
            expandedSkillUris.insert(skill.skillUri)
        }
    }

    private func hasExpandableContent(_ skill: CLISession.Metadata.Runtime.Skill) -> Bool {
        if let description = descriptionText(for: skill), !description.isEmpty {
            return true
        }
        return !skill.skillUri.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func displayName(for skill: CLISession.Metadata.Runtime.Skill) -> String {
        if let name = skill.name?.trimmingCharacters(in: .whitespacesAndNewlines),
           !name.isEmpty {
            if name.lowercased().hasPrefix("skill_") {
                return fallbackDisplayName(for: skill.skillUri)
            }
            return name
        }
        return fallbackDisplayName(for: skill.skillUri)
    }

    private func fallbackDisplayName(for skillUri: String) -> String {
        let trimmed = skillUri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "未命名技能" }
        if let last = trimmed.split(separator: "/").last {
            let candidate = String(last)
            if candidate.lowercased().hasPrefix("skill_") {
                return "未命名技能"
            }
            let humanized = candidate.replacingOccurrences(of: "-", with: " ")
            return humanized.isEmpty ? "未命名技能" : humanized
        }
        return "未命名技能"
    }

    private func descriptionText(for skill: CLISession.Metadata.Runtime.Skill) -> String? {
        guard let description = skill.description?.trimmingCharacters(in: .whitespacesAndNewlines),
              !description.isEmpty else {
            return nil
        }
        return description
    }

    private func isSystemSkill(_ skill: CLISession.Metadata.Runtime.Skill) -> Bool {
        if let explicit = skill.isSystem {
            return explicit
        }
        return skill.skillUri.lowercased().hasSuffix("/skill_creator")
    }
}

private struct CLIRenderedRunGroupList: View, Equatable {
    let version: Int
    let groups: [CLIRunGroup]
    let providerFlavor: String?
    let hasActiveRun: Bool
    let permissionActionInFlight: Set<String>
    let onAllowPermission: (String) -> Void
    let onAllowPermissionForSession: (String) -> Void
    let onDenyPermission: (String) -> Void

    static func == (lhs: CLIRenderedRunGroupList, rhs: CLIRenderedRunGroupList) -> Bool {
        lhs.version == rhs.version
            && lhs.providerFlavor == rhs.providerFlavor
            && lhs.hasActiveRun == rhs.hasActiveRun
            && lhs.permissionActionInFlight == rhs.permissionActionInFlight
    }

    var body: some View {
        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
            CLIRunGroupView(
                group: group,
                providerFlavor: providerFlavor,
                hasActiveRun: hasActiveRun,
                isLatestGroup: index == groups.count - 1,
                permissionActionInFlight: permissionActionInFlight,
                onAllowPermission: onAllowPermission,
                onAllowPermissionForSession: onAllowPermissionForSession,
                onDenyPermission: onDenyPermission
            )
            .id(group.id)
        }
    }
}

private struct BottomAnchorMaxYPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ScrollViewportHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SessionDetailView(
            session: CLISession.sample,
            client: RelayClient(
                serverURL: URL(string: CoreServerDefaults.relayServerURL)!,
                token: "test",
                botId: "preview-bot"
            )
        )
    }
}
