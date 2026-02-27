//
//  SessionMessage.swift
//  contextgo
//
//  消息模型（JSONL 格式）
//

import Foundation

/// 消息模型（JSONL 每行一条）
struct SessionMessage: Codable {
    let id: String              // 消息唯一 ID
    let sessionId: String       // 所属 Session ID
    let timestamp: Date         // 时间戳
    let role: MessageRole       // user / assistant / system / tool
    let content: String         // 消息内容

    // 工具执行相关（可选）
    var toolCalls: [ToolCall]?
    var toolResults: [ToolResult]?

    // 元数据（渠道专属字段）
    var metadata: [String: AnyCodable]?
}

/// 消息角色
enum MessageRole: String, Codable {
    case user
    case assistant
    case system
    case tool
}

/// 工具调用
struct ToolCall: Codable {
    let id: String
    let name: String
    let input: String?
}

/// 工具结果
struct ToolResult: Codable {
    let toolCallId: String
    let output: String?
    let error: String?
}

// Note: AnyCodable is defined in Core/Models/AnyCodable.swift
