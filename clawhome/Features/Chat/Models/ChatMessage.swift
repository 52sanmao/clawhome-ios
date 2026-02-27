//
//  ChatMessage.swift
//  contextgo
//
//  Chat message model
//

import Foundation

struct ChatMessage: Identifiable, Equatable, Codable {
    let id: UUID
    var text: String
    let isUser: Bool
    let timestamp: Date
    var isStreaming: Bool

    // Audio support
    var audioData: Data?
    var audioDuration: TimeInterval?
    var isAudioMessage: Bool {
        return audioData != nil
    }

    // Tool execution support (OpenClaw protocol)
    var toolExecutions: [ToolExecution]?

    // Lifecycle state (OpenClaw protocol)
    var lifecycleState: AgentLifecycleState?

    // Error information (OpenClaw protocol)
    var errorInfo: AgentErrorInfo?

    init(id: UUID = UUID(), text: String, isUser: Bool, timestamp: Date = Date(), isStreaming: Bool = false, audioData: Data? = nil, audioDuration: TimeInterval? = nil, toolExecutions: [ToolExecution]? = nil, lifecycleState: AgentLifecycleState? = nil, errorInfo: AgentErrorInfo? = nil) {
        self.id = id
        self.text = text
        self.isUser = isUser
        self.timestamp = timestamp
        self.isStreaming = isStreaming
        self.audioData = audioData
        self.audioDuration = audioDuration
        self.toolExecutions = toolExecutions
        self.lifecycleState = lifecycleState
        self.errorInfo = errorInfo
    }

    // MARK: - Codable
    enum CodingKeys: String, CodingKey {
        case id, text, isUser, timestamp, isStreaming, audioData, audioDuration, toolExecutions, lifecycleState, errorInfo
    }
}

// MARK: - Tool Execution Models

/// Represents a tool execution event from OpenClaw Agent
struct ToolExecution: Identifiable, Equatable, Codable {
    let id: String // toolId from the event
    var runId: String?
    var name: String
    var phase: ToolPhase
    var input: String?
    var output: String?
    var error: String?
    var startTime: Date
    var endTime: Date?

    enum ToolPhase: String, Codable {
        case start = "start"
        case update = "update"
        case result = "result"
    }

    var status: ToolStatus {
        switch phase {
        case .start:
            return .running
        case .update:
            return .running
        case .result:
            if error != nil {
                return .failed
            } else {
                return .completed
            }
        }
    }

    enum ToolStatus: String, Codable {
        case running = "running"
        case completed = "completed"
        case failed = "failed"
    }
}

// MARK: - Lifecycle Models

/// Represents agent lifecycle state
struct AgentLifecycleState: Equatable, Codable {
    var phase: LifecyclePhase
    var timestamp: Date

    enum LifecyclePhase: String, Codable {
        case start = "start"
        case end = "end"
        case error = "error"
    }
}

// MARK: - Error Models

/// Represents an error from the agent
struct AgentErrorInfo: Equatable, Codable {
    var message: String
    var code: String?
    var details: String?
    var timestamp: Date
}
