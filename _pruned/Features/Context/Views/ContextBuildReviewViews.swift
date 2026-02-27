import SwiftUI
import PhotosUI
import AVFoundation

// Import required types from Chat feature
// (ThemeColors, InputMode, RecordingState, AttachmentItem, ChatInputBar, ChatToolbar)

// MARK: - Models

struct DraftContext: Identifiable {
    let id = UUID()
    var title: String
    var content: String
    var date: Date
}

// MARK: - 1. Build Context View

struct BuildContextView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var isInputFocused: Bool

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    // ✅ Services
    @StateObject private var meetingRecordingManager = MeetingRecordingManager.shared
    @StateObject private var contextService = ContextService.shared
    @StateObject private var fileASRService = FileASRService.shared
    @StateObject private var spaceViewModel = SpaceViewModel()
    @StateObject private var realtimeAudioManager = RealtimeAudioManager.shared
    @StateObject private var attachmentService = AttachmentService.shared

    // ✅ Input States (Using ChatInputBar/ChatToolbar states)
    @State private var inputText = ""
    @State private var inputMode: InputMode = .text
    @State private var recordingState: RecordingState = .idle
    @State private var recordingDuration: TimeInterval = 0
    @State private var selectedAttachments: [AttachmentItem] = []
    @State private var sentAttachments: [AttachmentItem] = []
    @State private var showAttachmentPicker = false
    @State private var recognizedText = ""
    @State private var latestMeetingTranscript = ""
    @State private var latestMeetingAudioName = ""
    @State private var latestMeetingEventAt: Date?
    @State private var isHoldingSpeakButton = false
    @State private var audioPlayer: AVAudioPlayer?
    @State private var playingAttachmentID: UUID?

    // ✅ NEW: Meeting recording states
    @State private var isMeetingRecording = false
    @State private var meetingPhase: MeetingRecordingPhase = .ready
    @State private var isProcessingRecording = false
    @State private var isSendingBuildInput = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var meetingSegmentTask: Task<Void, Never>?
    @State private var lastSegmentFailureAt: Date?

    // ✅ NEW: Space selection
    @State private var selectedSpace: Space?
    @State private var showSpaceSelector = false

    // Mock Data for Visual Prompt
    let inputTypes: [(String, String, Color, String)] = [
        ("Text", "text.bubble.fill", .blue, "文字"),
        ("Voice", "mic.fill", .orange, "录音"),
        ("Image", "photo.fill", .green, "图片"),
        ("Video", "video.fill", .purple, "视频"),
        ("File", "doc.fill", .cyan, "文件")
    ]

    private let segmentIntervalSeconds: TimeInterval = 8
    private let segmentMinimumSeconds: TimeInterval = 12
    private let segmentFailureBackoffSeconds: TimeInterval = 16

    var body: some View {
        ZStack {
            theme.primaryBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 0) {
                    HStack {
                        Text("Build new context")
                            .font(.title2).bold()
                            .foregroundColor(theme.primaryText)

                        Spacer()

                        // ✅ Space Selector (compact style, same row as title)
                        Button(action: {
                            showSpaceSelector = true
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "folder.fill")
                                    .font(.caption)
                                    .foregroundColor(theme.secondaryText)

                                Text(selectedSpace?.displayName ?? "选择 Space")
                                    .font(.subheadline)
                                    .foregroundColor(theme.primaryText)

                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(theme.tertiaryText)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.cardBackground)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.border, lineWidth: 1)
                            )
                        }

                        Spacer().frame(width: 12)

                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                    .padding(.bottom, 12)

                    Divider().background(theme.border)
                }
                .background(theme.primaryBackground.opacity(0.8))

                Spacer()

                // Visual Prompts (Center Area)
                if inputText.isEmpty && selectedAttachments.isEmpty && sentAttachments.isEmpty {
                    VStack(spacing: 30) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Drop Everything")
                                .font(.title3).bold()
                                .foregroundColor(theme.primaryText.opacity(0.9))

                            Text("将会变成有价值的context")
                                .font(.subheadline)
                                .foregroundColor(theme.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 40)

                        HStack(spacing: 20) {
                            ForEach(inputTypes, id: \.0) { item in
                                VStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(item.2.opacity(0.2))
                                            .frame(width: 56, height: 56)
                                        Image(systemName: item.1)
                                            .font(.title2)
                                            .foregroundColor(item.2)
                                    }
                                    Text(item.3)
                                        .font(.caption)
                                        .foregroundColor(.white.opacity(0.6))
                                }
                            }
                        }

                        Text("Support text, voice, image, video, file and other contexts")
                            .font(.caption)
                            .foregroundColor(theme.tertiaryText)
                            .padding(.top, 10)
                    }
                    .padding(.bottom, 100)
                    .transition(.opacity)
                }

                if !sentAttachments.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("已发送附件")
                            .font(.subheadline.weight(.semibold))
                            .foregroundColor(theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(sentAttachments) { attachment in
                                    Button {
                                        handleSentAttachmentTap(attachment)
                                    } label: {
                                        AttachmentCard(
                                            attachment: attachment,
                                            onRemove: {},
                                            showsRemoveButton: false
                                        )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        Text("点击音频卡片可播放/暂停")
                            .font(.caption)
                            .foregroundColor(theme.tertiaryText)
                    }
                    .padding(.horizontal, 20)
                    .transition(.opacity)
                }

                if !latestMeetingTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                            Text("最新录音转写")
                                .font(.subheadline.weight(.semibold))
                                .foregroundColor(theme.secondaryText)
                            Spacer()
                        }

                        if !latestMeetingAudioName.isEmpty {
                            Text(latestMeetingAudioName)
                                .font(.caption)
                                .foregroundColor(theme.tertiaryText)
                        }

                        Text(latestMeetingTranscript)
                            .font(.footnote)
                            .foregroundColor(theme.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(theme.cardBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(theme.border, lineWidth: 1)
                            )

                        if let latestMeetingEventAt {
                            Text("已触发后端总结任务：\(relativeTimestamp(latestMeetingEventAt))")
                                .font(.caption2)
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .transition(.opacity)
                }

                Spacer()

                // ✅ Use ChatToolbar (without skills button)
                ChatToolbar(
                    recordingState: $recordingState,
                    onShowSkills: nil,  // ❌ No skills button for BuildContext
                    onShowUsageStats: nil,  // ❌ No usage stats button for BuildContext
                    onShowCronJobs: nil,  // ❌ No cron jobs button for BuildContext
                    onShowSettings: nil,  // ❌ No settings button for BuildContext
                    onShowThinking: nil  // ❌ No thinking level for BuildContext
                )

                // ✅ Use ChatInputBar
                ChatInputBar(
                    inputText: $inputText,
                    isInputFocused: $isInputFocused,
                    inputMode: $inputMode,
                    recordingState: $recordingState,
                    recordingDuration: $recordingDuration,
                    recognizedText: $recognizedText,
                    partialText: .constant(""),
                    isConnected: true,
                    isRecognizing: isProcessingRecording,
                    isMeetingRecording: isMeetingRecording,
                    meetingPhase: $meetingPhase,
                    containerBackground: theme.primaryBackground,
                    selectedAttachments: $selectedAttachments,
                    showAttachmentPicker: $showAttachmentPicker,
                    hasActiveRuns: false,
                    onStopRun: nil,
                    onSend: {
                        Task {
                            await handleBuildSend()
                        }
                    },
                    onCancelRecording: {
                        stopMeetingSegmentTranscription()
                        meetingRecordingManager.cancelRecording()
                        withAnimation(AnimationConfig.recordingSpring) {
                            isMeetingRecording = false
                            meetingPhase = .ready
                            recordingDuration = 0
                        }
                    },
                    onSendRecording: {
                        // Handle meeting recording completion
                        Task {
                            await handleSendMeetingRecording()
                        }
                    },
                    onHoldStartRecording: {
                        // Start hold-to-speak recording
                        isHoldingSpeakButton = true
                        recognizedText = ""

                        Task {
                            if !realtimeAudioManager.hasPermission {
                                let granted = await realtimeAudioManager.requestPermission()
                                if !granted {
                                    errorMessage = "需要麦克风权限才能录音"
                                    showError = true
                                    isHoldingSpeakButton = false
                                    return
                                }
                            }
                            do {
                                try realtimeAudioManager.startRecording()
                                print("🎤 [BuildContext] 按住说话录音已启动")
                            } catch {
                                print("❌ [BuildContext] 录音启动失败: \(error)")
                                errorMessage = error.localizedDescription
                                showError = true
                                isHoldingSpeakButton = false
                            }
                        }
                    },
                    onHoldSendRecording: {
                        // Finish hold-to-speak recording and transcribe
                        isHoldingSpeakButton = false
                        Task {
                            await handleHoldToSpeakFinish()
                        }
                    },
                    onStartMeetingRecording: {
                        meetingPhase = .recording
                        recognizedText = ""
                        lastSegmentFailureAt = nil
                        Task {
                            if !meetingRecordingManager.hasPermission {
                                let granted = await meetingRecordingManager.requestPermission()
                                if !granted {
                                    errorMessage = "需要麦克风权限才能录音"
                                    showError = true
                                    meetingPhase = .ready
                                    return
                                }
                            }
                            do {
                                try meetingRecordingManager.startRecording()
                                startMeetingSegmentTranscription()
                            } catch {
                                print("❌ [BuildContext] 启动录音失败: \(error)")
                                errorMessage = error.localizedDescription
                                showError = true
                                meetingPhase = .ready
                            }
                        }
                    },
                    onPauseMeetingRecording: {
                        meetingPhase = .paused
                        meetingRecordingManager.pauseRecording()
                    },
                    onResumeMeetingRecording: {
                        meetingPhase = .recording
                        meetingRecordingManager.resumeRecording()
                        if meetingSegmentTask == nil {
                            startMeetingSegmentTranscription()
                        }
                    },
                    onMeetingRecording: {
                        // Show meeting recording card
                        withAnimation(AnimationConfig.recordingSpring) {
                            isMeetingRecording = true
                            meetingPhase = .ready
                        }
                    },
                    onDismissMeetingRecording: {
                        stopMeetingSegmentTranscription()
                        meetingRecordingManager.cancelRecording()
                        withAnimation(AnimationConfig.recordingSpring) {
                            isMeetingRecording = false
                            meetingPhase = .ready
                        }
                    },
                    isHoldingSpeakButton: $isHoldingSpeakButton
                )
            }
        }
        .alert("错误", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "未知错误")
        }
        .onChange(of: meetingRecordingManager.recordingDuration) { _, newDuration in
            recordingDuration = newDuration
        }
        .onDisappear {
            // Clean up audio state when view disappears
            if isHoldingSpeakButton {
                isHoldingSpeakButton = false
                realtimeAudioManager.cancelRecording()
                print("🧹 [BuildContext] Cleaned up voice input state on disappear")
            }
            if isMeetingRecording {
                stopMeetingSegmentTranscription()
                meetingRecordingManager.cancelRecording()
                isMeetingRecording = false
                print("🧹 [BuildContext] Cleaned up meeting recording on disappear")
            }
            audioPlayer?.stop()
            audioPlayer = nil
            playingAttachmentID = nil
        }
        .task {
            // ✅ 加载 Space 列表并设置默认 Space
            await spaceViewModel.loadSpaces()
            if selectedSpace == nil {
                selectedSpace = spaceViewModel.defaultSpace
            }
        }
        .sheet(isPresented: $showSpaceSelector) {
            SpaceSelectorSheet(
                spaces: spaceViewModel.spaces,
                selectedSpace: $selectedSpace,
                colorScheme: colorScheme
            )
        }
    }

    private func handleSentAttachmentTap(_ attachment: AttachmentItem) {
        guard attachment.type == .audio else { return }

        do {
            if playingAttachmentID == attachment.id, let player = audioPlayer, player.isPlaying {
                player.stop()
                playingAttachmentID = nil
                return
            }

            let player = try AVAudioPlayer(data: attachment.fileData)
            player.prepareToPlay()
            if player.play() {
                audioPlayer = player
                playingAttachmentID = attachment.id
            } else {
                throw NSError(
                    domain: "BuildContext",
                    code: -4,
                    userInfo: [NSLocalizedDescriptionKey: "音频播放失败"]
                )
            }
        } catch {
            errorMessage = "无法播放音频：\(error.localizedDescription)"
            showError = true
        }
    }

    private func relativeTimestamp(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func handleBuildSend() async {
        guard !isSendingBuildInput else { return }

        let trimmedText = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachmentsSnapshot = selectedAttachments

        guard !trimmedText.isEmpty || !attachmentsSnapshot.isEmpty else { return }
        guard let selectedSpace else {
            errorMessage = "请先选择一个 Space"
            showError = true
            return
        }

        isSendingBuildInput = true
        defer { isSendingBuildInput = false }

        var uploadedUris: [String] = []
        var firstUploadError: Error?
        var successfulAttachmentIds = Set<UUID>()

        for attachment in attachmentsSnapshot {
            setAttachmentState(
                attachmentID: attachment.id,
                isUploading: true,
                uploadResult: nil,
                uploadError: nil
            )

            do {
                let uploaded = try await attachmentService.uploadFile(
                    fileData: attachment.fileData,
                    fileName: attachment.fileName,
                    mimeType: attachment.mimeType
                )
                uploadedUris.append(uploaded.attachmentUri)
                successfulAttachmentIds.insert(attachment.id)
                setAttachmentState(
                    attachmentID: attachment.id,
                    isUploading: false,
                    uploadResult: uploaded,
                    uploadError: nil
                )
            } catch {
                if firstUploadError == nil {
                    firstUploadError = error
                }
                setAttachmentState(
                    attachmentID: attachment.id,
                    isUploading: false,
                    uploadResult: nil,
                    uploadError: error.localizedDescription
                )
            }
        }

        if !trimmedText.isEmpty {
            let title = buildContextTitle(text: trimmedText, attachmentCount: uploadedUris.count)
            let contextBody = buildContextBody(text: trimmedText, attachmentUris: uploadedUris)
            do {
                _ = try await contextService.createContext(
                    spaceId: selectedSpace.id,
                    title: title,
                    content: contextBody,
                    description: nil,
                    tags: nil,
                    buildingSource: "ios.manual-build",
                    buildingSourceId: nil,
                    attachmentUris: uploadedUris.isEmpty ? nil : uploadedUris
                )
            } catch {
                errorMessage = "创建 Context 失败: \(error.localizedDescription)"
                showError = true
            }
        }

        let successfulCards = selectedAttachments
            .filter { successfulAttachmentIds.contains($0.id) }
            .map { item -> AttachmentItem in
                var card = item
                card.isUploading = false
                return card
            }
        if !successfulCards.isEmpty {
            sentAttachments.insert(contentsOf: successfulCards, at: 0)
            if sentAttachments.count > 30 {
                sentAttachments = Array(sentAttachments.prefix(30))
            }
            selectedAttachments.removeAll { successfulAttachmentIds.contains($0.id) }
        }

        if selectedAttachments.isEmpty {
            inputText = ""
        }

        if let firstUploadError {
            errorMessage = "部分附件上传失败: \(firstUploadError.localizedDescription)"
            showError = true
        }
    }

    private func setAttachmentState(
        attachmentID: UUID,
        isUploading: Bool,
        uploadResult: AttachmentUploadResult?,
        uploadError: String?
    ) {
        guard let index = selectedAttachments.firstIndex(where: { $0.id == attachmentID }) else { return }
        selectedAttachments[index].isUploading = isUploading
        selectedAttachments[index].uploadResult = uploadResult
        selectedAttachments[index].uploadError = uploadError
    }

    private func buildContextTitle(text: String, attachmentCount: Int) -> String {
        if !text.isEmpty {
            return String(text.prefix(50))
        }
        return attachmentCount > 0 ? "附件归档（\(attachmentCount)）" : "Build Context"
    }

    private func buildContextBody(text: String, attachmentUris: [String]) -> String {
        let header = "附件归档 (ctxgo://)"
        let refs = attachmentUris.map { "- \($0)" }
        let refBlock = ([header] + refs).joined(separator: "\n")

        if text.isEmpty {
            return refBlock
        }
        if attachmentUris.isEmpty {
            return text
        }
        return "\(text)\n\n\(refBlock)"
    }

    // MARK: - Handle Hold-to-Speak Recording

    private func handleHoldToSpeakFinish() async {
        isProcessingRecording = true
        defer { isProcessingRecording = false }

        do {
            // Stop recording and get audio data
            let audioData = realtimeAudioManager.stopRecording()
            print("🎤 [BuildContext] 录音已停止，大小: \(audioData.count) bytes")

            guard audioData.count > 0 else {
                throw NSError(domain: "BuildContext", code: -1, userInfo: [NSLocalizedDescriptionKey: "录音数据为空"])
            }

            // Save as WAV file
            guard let wavURL = realtimeAudioManager.saveAsWAVFile(audioData) else {
                throw NSError(domain: "BuildContext", code: -1, userInfo: [NSLocalizedDescriptionKey: "保存音频文件失败"])
            }

            // Recognize audio using ASR
            print("🎤 [BuildContext] 开始识别音频...")
            let recognizedTextContent = try await fileASRService.transcribeFile(wavURL)

            await MainActor.run {
                recognizedText = recognizedTextContent
                inputText = recognizedTextContent
            }

            print("✅ [BuildContext] 音频识别完成: \(recognizedTextContent.prefix(50))...")

            // Clean up temp file
            try? FileManager.default.removeItem(at: wavURL)

        } catch {
            print("❌ [BuildContext] 按住说话处理失败: \(error)")
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    // MARK: - Chunked Meeting ASR

    private var segmentMinimumBytes: Int {
        Int(32000 * segmentMinimumSeconds) // 16kHz * 16bit mono = 32000 bytes/s
    }

    private func startMeetingSegmentTranscription() {
        stopMeetingSegmentTranscription()
        meetingSegmentTask = Task {
            while !Task.isCancelled {
                let nanos = UInt64(segmentIntervalSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                await transcribeBufferedMeetingSegment(force: false)
            }
        }
    }

    private func stopMeetingSegmentTranscription() {
        meetingSegmentTask?.cancel()
        meetingSegmentTask = nil
    }

    private func transcribeBufferedMeetingSegment(force: Bool) async {
        guard meetingRecordingManager.isRecording else { return }
        if !force, meetingPhase != .recording { return }

        if !force, let failedAt = lastSegmentFailureAt {
            let cooling = Date().timeIntervalSince(failedAt)
            if cooling < segmentFailureBackoffSeconds {
                return
            }
        }

        let chunk = meetingRecordingManager.extractSegmentBuffer(
            minimumBytes: force ? 1 : segmentMinimumBytes,
            force: force
        )
        guard !chunk.isEmpty else { return }

        do {
            let transcript = try await transcribeChunk(chunk)
            appendTranscriptSegment(transcript)
            lastSegmentFailureAt = nil
        } catch {
            lastSegmentFailureAt = Date()
            print("⚠️ [BuildContext] 分段转写失败，将退避重试: \(error)")
        }
    }

    private func transcribeChunk(_ chunk: Data) async throws -> String {
        guard let wavURL = meetingRecordingManager.saveAsWAVFile(chunk) else {
            throw NSError(
                domain: "BuildContext",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "分段音频写入失败"]
            )
        }
        defer { try? FileManager.default.removeItem(at: wavURL) }
        return try await fileASRService.transcribeFile(wavURL)
    }

    private func appendTranscriptSegment(_ segment: String) {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            recognizedText = trimmed
        } else {
            recognizedText += "\n" + trimmed
        }
    }

    // MARK: - Handle Meeting Recording Completion

    private func handleSendMeetingRecording() async {
        guard !isProcessingRecording else {
            print("⚠️ [BuildContext] 忽略重复提交：录音处理仍在进行中")
            return
        }
        isProcessingRecording = true
        defer { isProcessingRecording = false }

        do {
            guard let selectedSpace = selectedSpace else {
                throw NSError(domain: "BuildContext", code: -2, userInfo: [NSLocalizedDescriptionKey: "请先选择一个 Space"])
            }

            stopMeetingSegmentTranscription()
            await transcribeBufferedMeetingSegment(force: true)

            // Step 1: Stop recording and get audio data
            print("📝 [BuildContext] Step 1: 停止录音")
            let audioData = meetingRecordingManager.stopRecording()

            await MainActor.run {
                withAnimation(AnimationConfig.recordingSpring) {
                    isMeetingRecording = false
                    meetingPhase = .ready
                }
            }

            guard audioData.count > 0 else {
                throw ContextError.invalidContent
            }

            let currentDate = Date()
            let dateFormatter = DateFormatter()
            dateFormatter.locale = Locale(identifier: "en_US_POSIX")
            dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            dateFormatter.dateFormat = "yyyy-MM-dd"
            let dateString = dateFormatter.string(from: currentDate)
            let dateKey = dateString.replacingOccurrences(of: "-", with: "")

            // Generate filename with timestamp
            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.timeZone = TimeZone(secondsFromGMT: 0)
            timeFormatter.dateFormat = "HHmmss"
            let timeString = timeFormatter.string(from: currentDate)
            let audioFileName = "meeting_\(timeString).wav"
            let transcriptFileName = "meeting_\(timeString).md"

            // Step 2: Save WAV into local archive path
            print("📝 [BuildContext] Step 2: 写入本地归档目录")
            guard let tempWavURL = meetingRecordingManager.saveAsWAVFile(audioData) else {
                throw NSError(domain: "BuildContext", code: -1, userInfo: [NSLocalizedDescriptionKey: "保存音频文件失败"])
            }
            let archiveDirectory = try ensureMeetingArchiveDirectory(dateKey: dateKey)
            let archivedAudioURL = archiveDirectory.appendingPathComponent(audioFileName)
            try replaceFileIfExists(at: archivedAudioURL)
            try FileManager.default.moveItem(at: tempWavURL, to: archivedAudioURL)

            var recognizedTextContent = recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            if recognizedTextContent.isEmpty {
                print("📝 [BuildContext] Step 3: 兜底全量识别音频")
                recognizedTextContent = try await fileASRService.transcribeFile(archivedAudioURL)
                await MainActor.run {
                    recognizedText = recognizedTextContent
                }
            }

            print("📝 [BuildContext] Step 4: 生成转写 Markdown 附件")
            let markdownContent = buildMeetingAttachmentMarkdown(
                dateString: dateString,
                audioFileName: audioFileName,
                transcript: recognizedTextContent
            )
            let transcriptURL = archiveDirectory.appendingPathComponent(transcriptFileName)
            let markdownData = Data(markdownContent.utf8)
            try markdownData.write(to: transcriptURL, options: .atomic)

            print("📝 [BuildContext] Step 5: 上传音频与纪要附件到 Core Storage Provider")
            let audioFileData = try Data(contentsOf: archivedAudioURL)
            let audioUpload = try await attachmentService.uploadFile(
                fileData: audioFileData,
                fileName: audioFileName,
                mimeType: "audio/wav"
            )
            let transcriptUpload = try await attachmentService.uploadFile(
                fileData: markdownData,
                fileName: transcriptFileName,
                mimeType: "text/markdown"
            )
            print("📝 [BuildContext] Step 6: 触发 Core 事件驱动摘要与 Context 创建")
            _ = try await contextService.emitMeetingNotesUploadedEvent(
                spaceId: selectedSpace.id,
                audioAttachmentUri: audioUpload.attachmentUri,
                transcriptAttachmentUri: transcriptUpload.attachmentUri,
                titleHint: String(recognizedTextContent.prefix(50)),
                source: .iosContextBuildMeetingRecording,
                provider: .contextgoCore
            )
            print("✅ [BuildContext] 已触发 Core 后端摘要任务")

            await MainActor.run {
                var audioCard = AttachmentItem(
                    fileName: audioFileName,
                    fileData: audioFileData,
                    mimeType: "audio/wav",
                    type: .audio
                )
                audioCard.uploadResult = audioUpload
                audioCard.isUploading = false

                var transcriptCard = AttachmentItem(
                    fileName: transcriptFileName,
                    fileData: markdownData,
                    mimeType: "text/markdown",
                    type: .file
                )
                transcriptCard.uploadResult = transcriptUpload
                transcriptCard.isUploading = false

                sentAttachments.insert(contentsOf: [audioCard, transcriptCard], at: 0)
                if sentAttachments.count > 30 {
                    sentAttachments = Array(sentAttachments.prefix(30))
                }

                latestMeetingTranscript = recognizedTextContent
                latestMeetingAudioName = audioFileName
                latestMeetingEventAt = Date()
                recognizedText = ""
                recordingDuration = 0
            }

        } catch {
            print("❌ [BuildContext] 处理录音失败: \(error)")
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
                isMeetingRecording = false
                meetingPhase = .ready
            }
        }
    }

    private func ensureMeetingArchiveDirectory(dateKey: String) throws -> URL {
        let userId = AuthService.shared.currentUser?.id ?? SessionStorageLayout.defaultLocalUserId
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = documents
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("users", isDirectory: true)
            .appendingPathComponent(SessionStorageLayout.encodePathComponent(userId), isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
            .appendingPathComponent(dateKey, isDirectory: true)
            .appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func replaceFileIfExists(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func buildMeetingAttachmentMarkdown(
        dateString: String,
        audioFileName: String,
        transcript: String
    ) -> String {
        """
        # 会议纪要

        - 日期: \(dateString)
        - 音频文件: \(audioFileName)

        ## 录音转写

        \(transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_（识别失败）_" : transcript)
        """
    }
}

// MARK: - 2. Review Context View

struct ReviewContextView: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @FocusState private var isInputFocused: Bool

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    // ✅ Services
    @StateObject private var contextService = ContextService.shared
    @StateObject private var spaceViewModel = SpaceViewModel()
    @StateObject private var realtimeAudioManager = RealtimeAudioManager.shared
    @StateObject private var fileASRService = FileASRService.shared

    // Data State
    @State private var contexts: [ContextMetadata] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showSuccessBanner = false
    @State private var successMessage = ""

    @State private var currentIndex = 0
    @State private var selectedSpace: Space?
    @State private var showSpaceSelector = false

    private var currentContext: ContextMetadata? {
        guard contexts.indices.contains(currentIndex) else { return nil }
        return contexts[currentIndex]
    }

    private var currentSpaceName: String {
        currentContext?.spaceId ?? selectedSpace?.displayName ?? "选择 Space"
    }

    private var currentSpaceContextCount: Int {
        guard let spaceId = currentContext?.spaceId ?? selectedSpace?.id else { return 0 }
        return contexts.filter { $0.spaceId == spaceId }.count
    }

    // ✅ Input States (Using ChatInputBar/ChatToolbar states)
    @State private var inputText = ""
    @State private var inputMode: InputMode = .text
    @State private var recordingState: RecordingState = .idle
    @State private var recordingDuration: TimeInterval = 0
    @State private var selectedAttachments: [AttachmentItem] = []
    @State private var showAttachmentPicker = false
    @State private var isHoldingSpeakButton = false
    @State private var recognizedText = ""
    @State private var isProcessingRecording = false

    // ✅ NEW: Meeting recording states
    @State private var isMeetingRecording = false
    @State private var meetingPhase: MeetingRecordingPhase = .ready

    var body: some View {
        ZStack {
            theme.primaryBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                VStack(spacing: 0) {
                    HStack {
                        Text("Review Context (\(contexts.count))")
                            .font(.headline)
                            .foregroundColor(theme.primaryText)
                        Spacer()

                        Button(action: {
                            showSpaceSelector = true
                        }) {
                            HStack(spacing: 6) {
                                Text(currentSpaceName)
                                    .font(.caption)
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(1)

                                if currentSpaceContextCount > 0 {
                                    Text("\(currentSpaceContextCount)")
                                        .font(.caption2)
                                        .foregroundColor(theme.primaryText)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(theme.secondaryBackground)
                                        .cornerRadius(8)
                                }

                                Image(systemName: "chevron.down")
                                    .font(.caption2)
                                    .foregroundColor(theme.secondaryText)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(theme.cardBackground)
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(theme.border, lineWidth: 1)
                            )
                        }

                        // Refresh button
                        if !isLoading {
                            Button(action: {
                                Task {
                                    await loadContexts()
                                }
                            }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.body)
                                    .foregroundColor(theme.secondaryText)
                            }
                        }

                        Button(action: { dismiss() }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.title2)
                                .foregroundColor(theme.tertiaryText)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 20)

                    Divider().background(theme.border)
                }
                .background(theme.primaryBackground.opacity(0.8))

                if isLoading {
                    Spacer()
                    ProgressView("加载中...")
                        .tint(.blue)
                    Spacer()
                } else if contexts.isEmpty {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "tray")
                            .font(.system(size: 48))
                            .foregroundColor(theme.secondaryText)
                        Text("暂无 Context")
                            .font(.headline)
                            .foregroundColor(theme.primaryText)
                        Text("开始创建你的第一个 Context")
                            .font(.subheadline)
                            .foregroundColor(theme.secondaryText)
                    }
                    Spacer()
                } else {
                    // Carousel
                    TabView(selection: $currentIndex) {
                        ForEach(contexts.indices, id: \.self) { index in
                            ReviewCard(
                                context: contexts[index],
                                colorScheme: colorScheme,
                                onArchive: {
                                    archiveDraft(at: index)
                                }
                            )
                            .tag(index)
                            .padding(.horizontal, 10)
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(maxHeight: .infinity)
                }

                // ✅ Use ChatToolbar (without skills button)
                ChatToolbar(
                    recordingState: $recordingState,
                    onShowSkills: nil,  // ❌ No skills button
                    onShowUsageStats: nil,  // ❌ No usage stats button
                    onShowCronJobs: nil,  // ❌ No cron jobs button
                    onShowSettings: nil,  // ❌ No settings button
                    onShowThinking: nil  // ❌ No thinking level
                )

                // ✅ Use ChatInputBar
                ChatInputBar(
                    inputText: $inputText,
                    isInputFocused: $isInputFocused,
                    inputMode: $inputMode,
                    recordingState: $recordingState,
                    recordingDuration: $recordingDuration,
                    recognizedText: .constant(""),
                    partialText: .constant(""),
                    isConnected: true,
                    isRecognizing: false,
                    isMeetingRecording: isMeetingRecording,
                    meetingPhase: $meetingPhase,
                    containerBackground: theme.primaryBackground,
                    selectedAttachments: $selectedAttachments,
                    showAttachmentPicker: $showAttachmentPicker,
                    hasActiveRuns: false,
                    onStopRun: nil,
                    onSend: {
                        // Handle feedback
                        inputText = ""
                        selectedAttachments.removeAll()
                    },
                    onCancelRecording: {
                        withAnimation(AnimationConfig.recordingSpring) {
                            isMeetingRecording = false
                            meetingPhase = .ready
                            recordingDuration = 0
                        }
                    },
                    onSendRecording: {
                        // Handle recording send
                        withAnimation(AnimationConfig.recordingSpring) {
                            isMeetingRecording = false
                            meetingPhase = .ready
                        }
                    },
                    onHoldStartRecording: {
                        // Start hold-to-speak recording for feedback
                        isHoldingSpeakButton = true
                        recognizedText = ""

                        Task {
                            if !realtimeAudioManager.hasPermission {
                                let granted = await realtimeAudioManager.requestPermission()
                                if !granted {
                                    errorMessage = "需要麦克风权限才能录音"
                                    showError = true
                                    isHoldingSpeakButton = false
                                    return
                                }
                            }
                            do {
                                try realtimeAudioManager.startRecording()
                                print("🎤 [ReviewContext] 按住说话录音已启动")
                            } catch {
                                print("❌ [ReviewContext] 录音启动失败: \(error)")
                                errorMessage = error.localizedDescription
                                showError = true
                                isHoldingSpeakButton = false
                            }
                        }
                    },
                    onHoldSendRecording: {
                        // Finish hold-to-speak recording
                        isHoldingSpeakButton = false
                        Task {
                            await handleHoldToSpeakFinish()
                        }
                    },
                    onStartMeetingRecording: {
                        meetingPhase = .recording
                    },
                    onPauseMeetingRecording: {
                        meetingPhase = .paused
                    },
                    onResumeMeetingRecording: {
                        meetingPhase = .recording
                    },
                    onMeetingRecording: {
                        // Show meeting recording card
                        withAnimation(AnimationConfig.recordingSpring) {
                            isMeetingRecording = true
                            meetingPhase = .ready
                        }
                    },
                    onDismissMeetingRecording: {
                        withAnimation(AnimationConfig.recordingSpring) {
                            isMeetingRecording = false
                            meetingPhase = .ready
                        }
                    },
                    isHoldingSpeakButton: $isHoldingSpeakButton
                )
            }

            if showSuccessBanner {
                VStack {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                        Text(successMessage)
                            .font(.subheadline)
                            .foregroundColor(theme.primaryText)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(theme.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(theme.border, lineWidth: 1)
                    )
                    .cornerRadius(12)
                    .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 2)

                    Spacer()
                }
                .padding(.top, 16)
                .padding(.horizontal, 20)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .task {
            await spaceViewModel.loadSpaces()
            if selectedSpace == nil {
                selectedSpace = spaceViewModel.defaultSpace
            }
            await loadContexts()
        }
        .sheet(isPresented: $showSpaceSelector) {
            SpaceSelectorSheet(
                spaces: spaceViewModel.spaces,
                selectedSpace: $selectedSpace,
                colorScheme: colorScheme
            )
        }
        .onChange(of: selectedSpace?.id) { _, _ in
            guard let selectedSpace else { return }
            if let targetIndex = contexts.firstIndex(where: { $0.spaceId == selectedSpace.id }) {
                currentIndex = targetIndex
            }
        }
        .onChange(of: currentIndex) { _, newValue in
            guard contexts.indices.contains(newValue) else { return }
            let spaceId = contexts[newValue].spaceId
            if let matchedSpace = spaceViewModel.spaces.first(where: { $0.id == spaceId }) {
                selectedSpace = matchedSpace
            }
        }
        .alert("错误", isPresented: $showError) {
            Button("确定", role: .cancel) {}
        } message: {
            if let errorMessage = errorMessage {
                Text(errorMessage)
            }
        }
        .onDisappear {
            // Clean up audio state when view disappears
            if isHoldingSpeakButton {
                isHoldingSpeakButton = false
                realtimeAudioManager.cancelRecording()
                print("🧹 [ReviewContext] Cleaned up voice input state on disappear")
            }
        }
    }

    // MARK: - Handle Hold-to-Speak Recording

    private func handleHoldToSpeakFinish() async {
        isProcessingRecording = true
        defer { isProcessingRecording = false }

        do {
            // Stop recording and get audio data
            let audioData = realtimeAudioManager.stopRecording()
            print("🎤 [ReviewContext] 录音已停止，大小: \(audioData.count) bytes")

            guard audioData.count > 0 else {
                throw NSError(domain: "ReviewContext", code: -1, userInfo: [NSLocalizedDescriptionKey: "录音数据为空"])
            }

            // Save as WAV file
            guard let wavURL = realtimeAudioManager.saveAsWAVFile(audioData) else {
                throw NSError(domain: "ReviewContext", code: -1, userInfo: [NSLocalizedDescriptionKey: "保存音频文件失败"])
            }

            // Recognize audio using ASR
            print("🎤 [ReviewContext] 开始识别音频...")
            let recognizedTextContent = try await fileASRService.transcribeFile(wavURL)

            await MainActor.run {
                recognizedText = recognizedTextContent
                inputText = recognizedTextContent
            }

            print("✅ [ReviewContext] 音频识别完成: \(recognizedTextContent.prefix(50))...")

            // Clean up temp file
            try? FileManager.default.removeItem(at: wavURL)

        } catch {
            print("❌ [ReviewContext] 按住说话处理失败: \(error)")
            await MainActor.run {
                errorMessage = error.localizedDescription
                showError = true
            }
        }
    }

    func loadContexts() async {
        isLoading = true
        errorMessage = nil

        do {
            let pendingContexts = try await contextService.listContexts(status: "pending")
            await MainActor.run {
                contexts = pendingContexts
                // Reset to first card if current index is out of bounds
                if currentIndex >= contexts.count {
                    currentIndex = max(0, contexts.count - 1)
                }
                if let first = contexts.first,
                   selectedSpace == nil,
                   let matchedSpace = spaceViewModel.spaces.first(where: { $0.id == first.spaceId }) {
                    selectedSpace = matchedSpace
                }
                isLoading = false
            }
            print("✅ [ReviewContext] 加载了 \(contexts.count) 个待确认沉淀 Context (pending)")
        } catch {
            await MainActor.run {
                errorMessage = "加载失败: \(error.localizedDescription)"
                showError = true
                isLoading = false
            }
            print("❌ [ReviewContext] 加载失败: \(error)")
        }
    }

    func archiveDraft(at index: Int) {
        guard index < contexts.count else { return }
        let target = contexts[index]

        Task {
            do {
                try await contextService.updateContextStatus(contextId: target.id, status: "accepted")
                await MainActor.run {
                    withAnimation {
                        contexts.remove(at: index)
                        if currentIndex >= contexts.count {
                            currentIndex = max(0, contexts.count - 1)
                        }
                    }

                    successMessage = "已确认沉淀"
                    withAnimation(.easeOut(duration: 0.2)) {
                        showSuccessBanner = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        withAnimation(.easeIn(duration: 0.2)) {
                            showSuccessBanner = false
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = "更新状态失败: \(error.localizedDescription)"
                    showError = true
                }
            }
        }
    }
}

struct ReviewCard: View {
    let context: ContextMetadata
    let colorScheme: ColorScheme
    let onArchive: () -> Void

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    @State private var showEditor = false
    @State private var contextContent: String = ""
    @State private var isLoadingContent = false

    @StateObject private var contextService = ContextService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Card Header
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.title)
                        .font(.title3).bold()
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                }

                Spacer()

                Button(action: onArchive) {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Done")
                    }
                    .font(.caption).bold()
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.green.opacity(0.2))
                    .foregroundColor(.green)
                    .cornerRadius(8)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.3), lineWidth: 1))
                }
            }
            .padding(20)
            .background(theme.cardBackground)

            Divider().background(theme.border)

            // Content - Tappable to edit
            Button(action: {
                Task { await loadContentAndEdit() }
            }) {
                ScrollView {
                    if isLoadingContent {
                        ProgressView()
                            .padding(20)
                    } else if contextContent.isEmpty {
                        Text(context.description ?? "点击加载内容...")
                            .font(.body)
                            .foregroundColor(theme.secondaryText)
                            .lineSpacing(6)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        MarkdownText(markdown: contextContent, isUserMessage: false)
                            .padding(20)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .background(theme.secondaryBackground)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.border, lineWidth: 1))
        .padding(.vertical, 20)
        .task {
            await loadContent()
        }
        .fullScreenCover(isPresented: $showEditor) {
            MarkdownEditorView(content: $contextContent, title: context.title)
        }
    }

    func loadContent() async {
        guard contextContent.isEmpty else { return }
        isLoadingContent = true

        do {
            let content = try await contextService.downloadContent(contextId: context.id)
            await MainActor.run {
                contextContent = content
                isLoadingContent = false
            }
        } catch {
            await MainActor.run {
                contextContent = "加载失败: \(error.localizedDescription)"
                isLoadingContent = false
            }
        }
    }

    func loadContentAndEdit() async {
        if contextContent.isEmpty {
            await loadContent()
        }
        showEditor = true
    }
}

// MARK: - Space Selector Sheet

struct SpaceSelectorSheet: View {
    let spaces: [Space]
    @Binding var selectedSpace: Space?
    let colorScheme: ColorScheme
    @Environment(\.dismiss) var dismiss

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var body: some View {
        NavigationView {
            ZStack {
                theme.primaryBackground.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(spaces, id: \.id) { space in
                            Button(action: {
                                selectedSpace = space
                                dismiss()
                            }) {
                                HStack(spacing: 16) {
                                    // Left Checkmark
                                    Image(systemName: selectedSpace?.id == space.id ? "checkmark.circle.fill" : "circle")
                                        .font(.title2)
                                        .foregroundColor(selectedSpace?.id == space.id ? .blue : theme.primaryText.opacity(0.2))

                                    // Space Info
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(space.displayName)
                                            .font(.headline)
                                            .foregroundColor(theme.primaryText)

                                        if space.id == space.id { EmptyView() }
                                    }

                                    Spacer()
                                }
                                .padding(16)
                                .background(theme.cardBackground)
                                .cornerRadius(16)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16)
                                        .stroke(selectedSpace?.id == space.id ? Color.blue.opacity(0.5) : theme.border, lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("选择 Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                    .foregroundColor(.blue)
                }
            }
        }
    }
}
