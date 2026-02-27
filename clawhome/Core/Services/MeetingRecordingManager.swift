//
//  MeetingRecordingManager.swift
//  contextgo
//
//  Manager for long-form meeting/lecture recordings
//

import AVFoundation
import Foundation

@MainActor
class MeetingRecordingManager: NSObject, ObservableObject {
    static let shared = MeetingRecordingManager()

    // MARK: - Published Properties
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var hasPermission = false

    // MARK: - Private Properties
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioSession: AVAudioSession?
    private var recordingBuffer = Data()
    private var segmentBuffer = Data()
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?

    // MARK: - Initialization
    private override init() {
        super.init()
        // Check current permission status without requesting (no dialog shown on init)
        checkCurrentPermission()
    }

    // MARK: - Permission Handling

    private func checkCurrentPermission() {
        if #available(iOS 17.0, *) {
            hasPermission = AVAudioApplication.shared.recordPermission == .granted
        } else {
            hasPermission = AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    func requestPermission() async -> Bool {
        if hasPermission { return true }
        if #available(iOS 17.0, *) {
            let granted = await AVAudioApplication.requestRecordPermission()
            hasPermission = granted
            return granted
        } else {
            return await withCheckedContinuation { continuation in
                AVAudioSession.sharedInstance().requestRecordPermission { allowed in
                    Task { @MainActor in
                        self.hasPermission = allowed
                        continuation.resume(returning: allowed)
                    }
                }
            }
        }
    }

    // MARK: - Audio Session Setup (lazy, only called when recording starts)
    private func setupAudioSession() throws {
        audioSession = AVAudioSession.sharedInstance()

        // Configure and activate audio session only when recording starts
        // This ensures we don't interrupt background audio until user actually wants to record
        try audioSession?.setCategory(.record, mode: .measurement, options: [])
        try audioSession?.setActive(true)
        print("✅ 音频会话已配置并激活")
    }

    // MARK: - Recording Control

    /// Start meeting recording
    func startRecording() throws {
        guard hasPermission else {
            throw MeetingRecordingError.noPermission
        }

        guard !isRecording else { return }

        // ✅ Setup and activate audio session (lazy initialization)
        // This is when we actually interrupt background audio, not on init
        do {
            try setupAudioSession()
        } catch {
            print("❌ 音频会话配置失败: \(error)")
            throw MeetingRecordingError.sessionActivationFailed
        }

        // Create audio engine
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            throw MeetingRecordingError.engineInitFailed
        }

        inputNode = audioEngine.inputNode
        let inputFormat = inputNode!.outputFormat(forBus: 0)

        // Configure target format (16kHz, mono, PCM16)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw MeetingRecordingError.invalidFormat
        }

        // Install tap
        inputNode?.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: inputFormat
        ) { [weak self] buffer, time in
            Task { @MainActor in
                self?.processAudioBuffer(buffer, targetFormat: targetFormat)
            }
        }

        // Start audio engine
        do {
            try audioEngine.start()
            isRecording = true
            isPaused = false
            recordingBuffer = Data()
            segmentBuffer = Data()
            recordingStartTime = Date()
            recordingDuration = 0

            // Start timer
            startTimer()

            print("✅ 开始会议录音 - 16kHz PCM16")
        } catch {
            print("❌ 启动音频引擎失败: \(error)")
            throw MeetingRecordingError.engineStartFailed
        }
    }

    /// Pause recording
    func pauseRecording() {
        guard isRecording && !isPaused else { return }

        isPaused = true
        recordingTimer?.invalidate()
        recordingTimer = nil

        print("⏸️ 暂停录音")
    }

    /// Resume recording
    func resumeRecording() {
        guard isRecording && isPaused else { return }

        isPaused = false
        recordingStartTime = Date().addingTimeInterval(-recordingDuration)
        startTimer()

        print("▶️ 继续录音")
    }

    /// Stop recording and return audio data
    func stopRecording() -> Data {
        guard isRecording else { return Data() }

        recordingTimer?.invalidate()
        recordingTimer = nil

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()

        isRecording = false
        isPaused = false
        recordingDuration = 0

        let finalData = recordingBuffer
        recordingBuffer = Data()
        segmentBuffer = Data()

        print("✅ 停止录音，总计: \(finalData.count) bytes (\(String(format: "%.1f", Double(finalData.count) / 32000.0))秒)")

        return finalData
    }

    /// Cancel recording
    func cancelRecording() {
        guard isRecording else { return }

        recordingTimer?.invalidate()
        recordingTimer = nil

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()

        isRecording = false
        isPaused = false
        recordingDuration = 0
        recordingBuffer = Data()
        segmentBuffer = Data()

        print("🗑️ 取消录音")
    }

    /// Extract buffered segment data for chunked ASR without affecting full recording buffer.
    /// - Parameters:
    ///   - minimumBytes: Return empty if segment buffer is smaller and `force` is false.
    ///   - force: Drain segment buffer regardless of size.
    func extractSegmentBuffer(minimumBytes: Int = 0, force: Bool = false) -> Data {
        guard !segmentBuffer.isEmpty else { return Data() }
        if !force, minimumBytes > 0, segmentBuffer.count < minimumBytes {
            return Data()
        }
        let data = segmentBuffer
        segmentBuffer = Data()
        return data
    }

    // MARK: - Private Methods

    private func startTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self, self.isRecording, !self.isPaused else { return }
                guard let startTime = self.recordingStartTime else { return }
                self.recordingDuration = Date().timeIntervalSince(startTime)
            }
        }
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard !isPaused else { return }

        // Create converter
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            print("❌ 无法创建音频转换器")
            return
        }

        // Calculate output frame count
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * targetFormat.sampleRate / buffer.format.sampleRate)
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            print("❌ 无法创建转换缓冲区")
            return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            print("❌ 音频转换错误: \(error)")
            return
        }

        // Convert to PCM16 data
        guard let channelData = convertedBuffer.int16ChannelData else {
            print("❌ 无法获取音频数据")
            return
        }

        let channelDataValue = channelData.pointee
        let channelDataPointer = UnsafeBufferPointer(
            start: channelDataValue,
            count: Int(convertedBuffer.frameLength)
        )

        // Convert to Data and append to buffer
        let data = Data(buffer: channelDataPointer)
        recordingBuffer.append(data)
        segmentBuffer.append(data)
    }

    // MARK: - File Export

    /// Save audio data as WAV file
    func saveAsWAVFile(_ audioData: Data) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "meeting_\(Date().timeIntervalSince1970).wav"
        let fileURL = tempDir.appendingPathComponent(fileName)

        // WAV header for 16kHz, mono, PCM16
        let sampleRate: UInt32 = 16000
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = sampleRate * UInt32(numChannels) * UInt32(bitsPerSample) / 8
        let blockAlign = numChannels * bitsPerSample / 8
        let dataSize = UInt32(audioData.count)
        let fileSize = dataSize + 36

        var header = Data()

        // Helper function to convert value to Data
        func dataFrom<T>(_ value: T) -> Data {
            var mutableValue = value
            return Swift.withUnsafeBytes(of: &mutableValue) { Data($0) }
        }

        // RIFF chunk
        header.append("RIFF".data(using: .ascii)!)
        header.append(dataFrom(fileSize))
        header.append("WAVE".data(using: .ascii)!)

        // fmt chunk
        header.append("fmt ".data(using: .ascii)!)
        header.append(dataFrom(UInt32(16)))  // fmt chunk size
        header.append(dataFrom(UInt16(1)))   // PCM format
        header.append(dataFrom(numChannels))
        header.append(dataFrom(sampleRate))
        header.append(dataFrom(byteRate))
        header.append(dataFrom(blockAlign))
        header.append(dataFrom(bitsPerSample))

        // data chunk
        header.append("data".data(using: .ascii)!)
        header.append(dataFrom(dataSize))

        // Write to file
        do {
            try (header + audioData).write(to: fileURL)
            print("✅ WAV file saved: \(fileURL.path)")
            return fileURL
        } catch {
            print("❌ Failed to save WAV file: \(error)")
            return nil
        }
    }
}

// MARK: - Errors

enum MeetingRecordingError: Error {
    case noPermission
    case sessionActivationFailed
    case engineInitFailed
    case engineStartFailed
    case invalidFormat
}
