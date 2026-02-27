//
//  AudioRecordingManager.swift
//  contextgo
//
//  Audio recording manager with AVAudioRecorder
//

import AVFoundation
import SwiftUI

@MainActor
class AudioRecordingManager: NSObject, ObservableObject {
    static let shared = AudioRecordingManager()

    // MARK: - Published Properties
    @Published var isRecording = false
    @Published var isPaused = false
    @Published var hasPermission = false

    // MARK: - Private Properties
    private var audioRecorder: AVAudioRecorder?
    private var recordingSession: AVAudioSession?
    private var currentRecordingURL: URL?

    // MARK: - Initialization
    private override init() {
        super.init()
        setupAudioSession()
    }

    // MARK: - Audio Session Setup
    private func setupAudioSession() {
        recordingSession = AVAudioSession.sharedInstance()

        do {
            // Only set category, don't activate session yet (lazy activation on startRecording)
            try recordingSession?.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])

            // Request microphone permission
            recordingSession?.requestRecordPermission { [weak self] allowed in
                Task { @MainActor in
                    self?.hasPermission = allowed
                    if !allowed {
                        print("❌ 麦克风权限被拒绝")
                    }
                }
            }
        } catch {
            print("❌ 音频会话配置失败: \(error)")
        }
    }

    // MARK: - Recording Control

    /// Start recording
    func startRecording() {
        guard hasPermission else {
            print("❌ 没有麦克风权限")
            return
        }

        // Activate audio session (lazy activation to avoid conflicts with camera)
        do {
            try recordingSession?.setActive(true)
        } catch {
            print("❌ 音频会话激活失败: \(error)")
            return
        }

        // Generate unique filename
        let filename = "recording_\(Date().timeIntervalSince1970).m4a"
        let audioFilename = getDocumentsDirectory().appendingPathComponent(filename)
        currentRecordingURL = audioFilename

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128000
        ]

        do {
            audioRecorder = try AVAudioRecorder(url: audioFilename, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.isMeteringEnabled = true
            audioRecorder?.record()

            isRecording = true
            isPaused = false

            print("✅ 开始录音: \(audioFilename.lastPathComponent)")
        } catch {
            print("❌ 录音启动失败: \(error)")
        }
    }

    /// Pause recording
    func pauseRecording() {
        guard isRecording, !isPaused else { return }

        audioRecorder?.pause()
        isPaused = true
        print("⏸️ 暂停录音")
    }

    /// Resume recording
    func resumeRecording() {
        guard isRecording, isPaused else { return }

        audioRecorder?.record()
        isPaused = false
        print("▶️ 继续录音")
    }

    /// Stop recording and return audio data
    func stopRecording() async -> (data: Data, duration: TimeInterval)? {
        guard let url = currentRecordingURL else {
            return nil
        }

        // Get duration before stopping
        let duration = audioRecorder?.currentTime ?? 0

        audioRecorder?.stop()

        isRecording = false
        isPaused = false

        // Deactivate audio session to free resources
        do {
            try recordingSession?.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ 音频会话停用失败: \(error)")
        }

        // Read audio file
        do {
            let data = try Data(contentsOf: url)
            print("✅ 录音完成，时长: \(String(format: "%.1f", duration))s, 大小: \(data.count / 1024)KB")
            return (data, duration)
        } catch {
            print("❌ 读取录音文件失败: \(error)")
            return nil
        }
    }

    /// Cancel recording and delete file
    func cancelRecording() {
        audioRecorder?.stop()

        if let url = currentRecordingURL {
            do {
                try FileManager.default.removeItem(at: url)
                print("🗑️ 已删除录音文件")
            } catch {
                print("❌ 删除录音文件失败: \(error)")
            }
        }

        isRecording = false
        isPaused = false
        currentRecordingURL = nil

        // Deactivate audio session to free resources
        do {
            try recordingSession?.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("⚠️ 音频会话停用失败: \(error)")
        }
    }

    /// Get current recording duration
    func getCurrentDuration() -> TimeInterval {
        return audioRecorder?.currentTime ?? 0
    }

    /// Get audio power level (for visualization)
    func getAudioLevel() -> Float {
        audioRecorder?.updateMeters()
        return audioRecorder?.averagePower(forChannel: 0) ?? -160
    }

    // MARK: - Helper Methods

    private func getDocumentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}

// MARK: - AVAudioRecorderDelegate
extension AudioRecordingManager: AVAudioRecorderDelegate {
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor in
            if !flag {
                print("❌ 录音未成功完成")
            }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor in
            if let error = error {
                print("❌ 录音编码错误: \(error)")
            }
        }
    }
}
