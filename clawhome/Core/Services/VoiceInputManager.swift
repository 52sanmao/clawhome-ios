//
//  VoiceInputManager.swift
//  contextgo
//
//  Global hold-to-speak recording + ASR orchestration.
//  Reuses RealtimeAudioManager (PCM16 capture) and FileASRService (Alibaba FunASR).
//  Complete recording is transcribed after user releases the button.
//

import SwiftUI
import UIKit
import AVFoundation

@MainActor
class VoiceInputManager: ObservableObject {

    // MARK: - Published State

    @Published var isRecording = false
    @Published var isRecognizing = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var errorMessage: String?
    @Published var showError = false

    // MARK: - Callback

    /// Called with the transcription result when ASR completes.
    var onTranscriptionComplete: ((String) -> Void)?

    // MARK: - Private

    private let audioManager = RealtimeAudioManager.shared
    private let asrService = FileASRService.shared
    private var recordingStartTime: Date?
    private var recordingTimer: Timer?
    private var isFinishingRecording = false

    // MARK: - Public API

    func startRecording() async {
        guard !isRecording else { return }

        // Clear previous state
        errorMessage = nil
        showError = false

        // Request microphone permission on first use (shows system dialog if needed)
        if !audioManager.hasPermission {
            let granted = await audioManager.requestPermission()
            guard granted else {
                errorMessage = "需要麦克风权限才能录音"
                showError = true
                return
            }
        }

        do {
            try audioManager.startRecording()
        } catch {
            errorMessage = "录音启动失败: \(error.localizedDescription)"
            showError = true
            return
        }

        isRecording = true
        recordingStartTime = Date()
        recordingDuration = 0

        // Duration timer (no segmentation)
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self = self, self.isRecording,
                      let start = self.recordingStartTime else {
                    timer.invalidate()
                    return
                }
                self.recordingDuration = Date().timeIntervalSince(start)
            }
        }

        // Haptic
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()
    }

    func stopRecordingAndTranscribe() async {
        guard !isFinishingRecording else { return }
        guard isRecording else { return }

        isFinishingRecording = true
        isRecording = false

        // Stop timer
        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = 0
        recordingStartTime = nil

        // Get complete audio data
        let audioData = audioManager.stopRecording()

        if audioData.count > 0 {
            // Show recognizing state
            isRecognizing = true

            // Save and transcribe complete recording
            if let wavURL = audioManager.saveAsWAVFile(audioData) {
                do {
                    let transcript = try await asrService.transcribeFile(wavURL)
                    try? FileManager.default.removeItem(at: wavURL)

                    // Finalize
                    await finalize(with: transcript)
                } catch {
                    try? FileManager.default.removeItem(at: wavURL)
                    print("[VoiceInput] ❌ ASR error: \(error)")
                    await finalize(with: "")
                }
            } else {
                await finalize(with: "")
            }
        } else {
            await finalize(with: "")
        }
    }

    private func finalize(with transcript: String) async {
        isRecognizing = false
        isFinishingRecording = false

        // Haptic
        let impact = UIImpactFeedbackGenerator(style: .heavy)
        impact.impactOccurred()

        if !transcript.isEmpty {
            onTranscriptionComplete?(transcript)
        }
    }

    func cancelRecording() {
        guard isRecording else { return }

        isRecording = false

        recordingTimer?.invalidate()
        recordingTimer = nil
        recordingDuration = 0
        recordingStartTime = nil

        _ = audioManager.stopRecording()

        let impact = UIImpactFeedbackGenerator(style: .light)
        impact.impactOccurred()
    }

    /// Reset all state (e.g. when overlay dismissed).
    func reset() {
        isRecording = false
        isRecognizing = false
        isFinishingRecording = false
        recordingDuration = 0
        recordingStartTime = nil
        recordingTimer?.invalidate()
        recordingTimer = nil
        errorMessage = nil
        showError = false
    }
}
