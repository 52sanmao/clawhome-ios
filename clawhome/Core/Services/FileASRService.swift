//
//  FileASRService.swift
//  contextgo
//
//  File-based audio transcription using DashScope
//

import Foundation

@MainActor
class FileASRService: ObservableObject {
    static let shared = FileASRService()

    @Published var isTranscribing = false
    @Published var errorMessage: String?

    private var webSocketTask: URLSessionWebSocketTask?
    private var taskId: String?

    // Configuration
    private let wsURL = ASRServiceConfig.Alibaba.wsURL
    private var apiKey: String { ASRServiceConfig.Alibaba.apiKey }
    private let model = "fun-asr-realtime"

    // Results
    private var sentenceBuffers: [Int: String] = [:]
    private var transcript = ""

    // Continuation for async result
    private var transcriptionContinuation: CheckedContinuation<String, Error>?

    // Streaming callback for real-time results
    var onPartialResult: ((String, Bool) -> Void)?  // (text, isFinal)

    // MARK: - Public API

    /// Transcribe audio file to text
    func transcribeFile(_ fileURL: URL) async throws -> String {
        guard !isTranscribing else {
            throw FileASRError.alreadyTranscribing
        }
        guard !apiKey.isEmpty else {
            throw FileASRError.missingAPIKey
        }

        // Reset state
        transcript = ""
        sentenceBuffers.removeAll()
        errorMessage = nil
        isTranscribing = true

        defer {
            isTranscribing = false
            transcriptionContinuation = nil
        }

        print("[FileASR] 📁 开始转写文件: \(fileURL.lastPathComponent)")

        return try await withCheckedThrowingContinuation { continuation in
            transcriptionContinuation = continuation

            Task {
                do {
                    // 1. Connect WebSocket
                    try await connectWebSocket()

                    // 2. Start listening for messages
                    Task {
                        await receiveMessages()
                    }

                    // 3. Send run-task
                    try await sendRunTask()

                    // 4. Send audio data
                    try await sendAudioFile(fileURL)

                    // 5. Send finish-task
                    try await sendFinishTask()

                    // Result will be returned via continuation in handleTextMessage

                } catch {
                    print("[FileASR] ❌ 错误: \(error)")
                    await MainActor.run {
                        self.errorMessage = error.localizedDescription
                        self.transcriptionContinuation?.resume(throwing: error)
                        self.transcriptionContinuation = nil
                    }
                }
            }
        }
    }

    // MARK: - WebSocket Connection

    private func connectWebSocket() async throws {
        guard let url = URL(string: wsURL) else {
            throw FileASRError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: request)
        webSocketTask?.resume()

        print("[FileASR] 🔌 WebSocket 已连接")
    }

    private func disconnectWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        print("[FileASR] 🔌 WebSocket 已断开")
    }

    // MARK: - Protocol Messages

    /// Phase 1: Send run-task
    private func sendRunTask() async throws {
        // ✅ Remove dashes from UUID like Node.js version
        taskId = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let message: [String: Any] = [
            "header": [
                "action": "run-task",
                "task_id": taskId!,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",      // ✅ Required field
                "task": "asr",
                "function": "recognition",  // ✅ Required field
                "model": model,
                "parameters": [
                    "format": "pcm",        // PCM format (our recording format)
                    "sample_rate": 16000    // 16kHz
                ],
                "input": [:]                // ✅ Required field (empty dict)
            ]
        ]

        try await sendJSON(message)
        print("[FileASR] ✅ 已发送 run-task, taskId: \(taskId!)")
    }

    /// Phase 2: Send audio file in chunks
    private func sendAudioFile(_ fileURL: URL) async throws {
        let audioData = try Data(contentsOf: fileURL)
        print("[FileASR] 📤 开始发送音频: \(audioData.count) bytes")

        let chunkSize = 16 * 1024  // 16KB per chunk
        var offset = 0

        while offset < audioData.count {
            let end = min(offset + chunkSize, audioData.count)
            let chunk = audioData[offset..<end]

            // Send chunk as binary
            let message = URLSessionWebSocketTask.Message.data(Data(chunk))
            try await webSocketTask?.send(message)

            offset = end

            // Small delay to avoid overwhelming server (50ms like Node.js version)
            try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
        }

        print("[FileASR] ✅ 音频发送完成")
    }

    /// Phase 3: Send finish-task
    private func sendFinishTask() async throws {
        guard let taskId = taskId else {
            throw FileASRError.noTaskId
        }

        let message: [String: Any] = [
            "header": [
                "action": "finish-task",
                "task_id": taskId,
                "streaming": "duplex"       // ✅ Required field
            ],
            "payload": [
                "input": [:]                // ✅ Required field (empty dict)
            ]
        ]

        try await sendJSON(message)
        print("[FileASR] ✅ 已发送 finish-task")
    }

    // MARK: - Message Handling

    private func receiveMessages() async {
        guard let webSocketTask = webSocketTask else { return }

        do {
            while true {
                let message = try await webSocketTask.receive()

                switch message {
                case .string(let text):
                    await handleTextMessage(text)
                case .data(let data):
                    print("[FileASR] ⚠️ 收到二进制消息: \(data.count) bytes")
                @unknown default:
                    break
                }
            }
        } catch {
            if shouldIgnoreReceiveError(error) {
                print("[FileASR] ℹ️ 接收循环已结束: \(error.localizedDescription)")
                return
            }
            print("[FileASR] ❌ 接收消息错误: \(error)")
        }
    }

    private func handleTextMessage(_ text: String) async {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any],
              let event = header["event"] as? String else {
            print("[FileASR] ⚠️ 无法解析消息: \(text.prefix(100))")
            return
        }

        print("[FileASR] 📨 收到事件: \(event)")

        switch event {
        case "task-started":
            print("[FileASR] ✅ 任务已启动")

        case "result-generated":
            await handleResultGenerated(json)

        case "task-finished":
            print("[FileASR] ✅ 任务已完成")
            print("[FileASR] 📝 最终转录: \(transcript)")
            disconnectWebSocket()

            // Resume with final transcript
            if let continuation = transcriptionContinuation {
                continuation.resume(returning: transcript)
                transcriptionContinuation = nil
            }

        case "task-failed":
            var errorMsg = "转写任务失败"
            if let payload = json["payload"] as? [String: Any] {
                // Print full payload for debugging
                print("[FileASR] ❌ task-failed payload: \(payload)")

                if let message = payload["message"] as? String {
                    errorMsg = message
                } else if let output = payload["output"] as? [String: Any],
                          let message = output["message"] as? String {
                    errorMsg = message
                }
                print("[FileASR] ❌ 任务失败: \(errorMsg)")
            } else {
                print("[FileASR] ❌ task-failed 无 payload")
            }

            await MainActor.run {
                self.errorMessage = errorMsg
            }
            disconnectWebSocket()

            // Resume with error
            if let continuation = transcriptionContinuation {
                continuation.resume(throwing: FileASRError.transcriptionFailed(errorMsg))
                transcriptionContinuation = nil
            }

        default:
            print("[FileASR] ⚠️ 未知事件: \(event)")
        }
    }

    private func handleResultGenerated(_ json: [String: Any]) async {
        // Print full JSON for debugging
        if let jsonData = try? JSONSerialization.data(withJSONObject: json),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            print("[FileASR] 📨 result-generated 完整消息: \(jsonString)")
        }

        guard let payload = json["payload"] as? [String: Any],
              let output = payload["output"] as? [String: Any],
              let sentence = output["sentence"] as? [String: Any],
              let sentenceId = sentence["sentence_id"] as? Int else {
            print("[FileASR] ⚠️ 无法解析识别结果")
            print("[FileASR] payload: \(json["payload"] as? [String: Any] ?? [:])")
            return
        }

        print("[FileASR] 📝 句子ID: \(sentenceId)")

        // Update sentence buffer
        if let text = sentence["text"] as? String {
            sentenceBuffers[sentenceId] = text
            print("[FileASR] 📝 文本片段: '\(text)'")

            // ✅ Notify partial result callback
            let sentenceEnd = sentence["sentence_end"] as? Bool ?? false
            await MainActor.run {
                self.onPartialResult?(text, sentenceEnd)
            }
        } else {
            print("[FileASR] ⚠️ 没有找到 text 字段")
        }

        // Check if sentence is complete
        let sentenceEnd = sentence["sentence_end"] as? Bool ?? false
        print("[FileASR] 📝 sentence_end: \(sentenceEnd)")

        if sentenceEnd {
            // Extract final text
            if let finalText = sentenceBuffers[sentenceId], !finalText.isEmpty {
                transcript += finalText
                print("[FileASR] 📝 句子完成: '\(finalText)'")
            } else {
                print("[FileASR] ⚠️ 句子完成但文本为空")
            }
            sentenceBuffers.removeValue(forKey: sentenceId)
        }
    }

    // MARK: - Helper Methods

    private func sendJSON(_ message: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        let text = String(data: data, encoding: .utf8)!
        let wsMessage = URLSessionWebSocketTask.Message.string(text)
        try await webSocketTask?.send(wsMessage)
    }

    private func shouldIgnoreReceiveError(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

// MARK: - Errors

enum FileASRError: LocalizedError {
    case alreadyTranscribing
    case missingAPIKey
    case invalidURL
    case noTaskId
    case transcriptionFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyTranscribing:
            return "已在转写中"
        case .missingAPIKey:
            return "未配置阿里云 ASR API Key（请设置环境变量 ASR_DASHSCOPE_API_KEY 或 Info.plist 键 ASR_DASHSCOPE_API_KEY）"
        case .invalidURL:
            return "无效的WebSocket URL"
        case .noTaskId:
            return "缺少任务ID"
        case .transcriptionFailed(let message):
            return "转写失败: \(message)"
        }
    }
}
