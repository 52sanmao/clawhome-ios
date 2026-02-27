//
//  RealtimeAudioManager.swift
//  contextgo
//
//  Simple audio recording manager (no streaming)
//

import AVFoundation
import Foundation

@MainActor
class RealtimeAudioManager: NSObject, ObservableObject {
    static let shared = RealtimeAudioManager()

    // MARK: - Published Properties
    @Published var isRecording = false
    @Published var hasPermission = false

    // MARK: - Callback
    var onAudioData: ((Data) -> Void)?

    // MARK: - Private Properties
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioSession: AVAudioSession?

    // Recording buffer (accumulate all audio data)
    private var recordingBuffer = Data()

    // MARK: - Initialization
    private override init() {
        super.init()
        // Check current permission status without requesting (no dialog shown on init)
        checkCurrentPermission()
    }

    // MARK: - Permission Handling

    /// Check current permission status without showing any dialog.
    private func checkCurrentPermission() {
        if #available(iOS 17.0, *) {
            hasPermission = AVAudioApplication.shared.recordPermission == .granted
        } else {
            hasPermission = AVAudioSession.sharedInstance().recordPermission == .granted
        }
    }

    /// Request microphone permission. Only shows system dialog the first time.
    /// Called lazily when the user actually taps the mic button.
    func requestPermission() async -> Bool {
        if hasPermission { return true }
        return await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { [weak self] allowed in
                    Task { @MainActor in
                        self?.hasPermission = allowed
                        if !allowed { print("❌ 麦克风权限被拒绝") }
                        continuation.resume(returning: allowed)
                    }
                }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission { [weak self] allowed in
                    Task { @MainActor in
                        self?.hasPermission = allowed
                        if !allowed { print("❌ 麦克风权限被拒绝") }
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

    /// Start recording (simple accumulation)
    func startRecording() throws {
        guard hasPermission else {
            throw AudioError.noPermission
        }

        // If already recording, stop previous recording first to avoid state pollution
        if isRecording {
            print("⚠️ [RealtimeAudioManager] Already recording, stopping previous recording first")
            _ = stopRecording()
        }

        // ✅ Setup and activate audio session (lazy initialization)
        // This is when we actually interrupt background audio, not on init
        do {
            try setupAudioSession()
        } catch {
            print("❌ 音频会话配置失败: \(error)")
            throw AudioError.sessionActivationFailed
        }

        // Create audio engine
        audioEngine = AVAudioEngine()

        guard let audioEngine = audioEngine else {
            throw AudioError.engineInitFailed
        }

        inputNode = audioEngine.inputNode

        // Use the input node's native format
        let inputFormat = inputNode!.outputFormat(forBus: 0)

        // Configure target format (16kHz, mono, PCM16)
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            throw AudioError.invalidFormat
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
            recordingBuffer = Data()
            print("✅ 开始录音 - 输入: \(inputFormat.sampleRate)Hz, 目标: 16kHz PCM16")
        } catch {
            print("❌ 启动音频引擎失败: \(error)")
            throw AudioError.engineStartFailed
        }
    }

    /// Stop recording and return audio data
    func stopRecording() -> Data {
        guard isRecording else { return Data() }

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()

        isRecording = false

        // Deactivate audio session to free resources
        do {
            try audioSession?.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ 音频会话停用失败: \(error)")
        }

        let finalData = recordingBuffer
        recordingBuffer = Data()

        print("✅ 停止录音，总计: \(finalData.count) bytes (\(String(format: "%.1f", Double(finalData.count) / 32000.0))秒)")

        return finalData
    }

    /// Extract current recording buffer without stopping (for segmented ASR)
    func extractRecordingBuffer() -> Data {
        let data = recordingBuffer
        recordingBuffer = Data()
        print("📦 提取录音片段: \(data.count) bytes (\(String(format: "%.1f", Double(data.count) / 32000.0))秒)")
        return data
    }

    /// Cancel recording
    func cancelRecording() {
        guard isRecording else { return }

        inputNode?.removeTap(onBus: 0)
        audioEngine?.stop()

        isRecording = false
        recordingBuffer = Data()

        // Deactivate audio session to free resources
        do {
            try audioSession?.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ 音频会话停用失败: \(error)")
        }

        print("🗑️ 取消录音")
    }

    // MARK: - Audio Processing

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        // 创建转换器
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            print("❌ 无法创建音频转换器")
            return
        }

        // 计算输出帧数
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

        // 转换为 PCM16 数据
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

        // Call callback if set (for real-time ASR)
        onAudioData?(data)
    }

    // MARK: - File Export

    /// Save audio data as WAV file
    func saveAsWAVFile(_ audioData: Data) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "recording_\(Date().timeIntervalSince1970).wav"
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

        // RIFF chunk
        header.append("RIFF".data(using: .ascii)!)
        header.append(Data(from: fileSize))
        header.append("WAVE".data(using: .ascii)!)

        // fmt chunk
        header.append("fmt ".data(using: .ascii)!)
        header.append(Data(from: UInt32(16)))  // fmt chunk size
        header.append(Data(from: UInt16(1)))   // PCM format
        header.append(Data(from: numChannels))
        header.append(Data(from: sampleRate))
        header.append(Data(from: byteRate))
        header.append(Data(from: blockAlign))
        header.append(Data(from: bitsPerSample))

        // data chunk
        header.append("data".data(using: .ascii)!)
        header.append(Data(from: dataSize))

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

enum AudioError: Error {
    case noPermission
    case engineInitFailed
    case engineStartFailed
    case invalidFormat
    case sessionActivationFailed
}

// MARK: - Helper Extensions

extension Data {
    init<T>(from value: T) {
        var mutableValue = value
        self = Swift.withUnsafeBytes(of: &mutableValue) { Data($0) }
    }
}
