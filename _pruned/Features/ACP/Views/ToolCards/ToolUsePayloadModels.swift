//
//  ToolUsePayloadModels.swift
//  contextgo
//
//  Shared payload model structs used by ToolUseView rendering.
//

import Foundation

struct ParsedReadOutput {
    let path: String?
    let type: String?
    let content: String?
    let entriesBlock: String?
}

struct ParsedTaskInput {
    let subagentType: String
    let description: String?
    let prompt: String?
}

struct TodoItemSnapshot: Identifiable {
    let id: String
    let content: String
    let status: String
    let priority: String?
}

struct ParsedBashInput {
    let command: String
    let cwd: String?
    let reason: String?
    let timeout: String?
}

struct ParsedBashOutput {
    let stdout: String?
    let stderr: String?
    let exitCode: String?
    let status: String?
    let processId: String?
    let command: String?
}

struct ParsedBackgroundTaskInput {
    let taskId: String?
    let state: String?
    let title: String?
    let detail: String?
    let extraPayload: String?
    let isMinimal: Bool
}

struct ParallelDispatchOperationSnapshot: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let icon: String
}

struct ParsedFileEditChange: Identifiable {
    let id: String
    let path: String
    let changeType: String?
    let movePath: String?
    let unifiedDiff: String?
    let addedLines: Int
    let deletedLines: Int
    let hunkCount: Int
}

struct ParsedFileEditInput {
    let autoApproved: Bool?
    let changes: [ParsedFileEditChange]
}

struct ParsedFileEditOutput {
    let success: Bool?
    let stdout: String?
    let stderr: String?
    let updatedFiles: [String]
}
