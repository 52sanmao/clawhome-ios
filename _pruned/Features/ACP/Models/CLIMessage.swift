//
//  CLIMessage.swift
//  contextgo
//
//  CLI relay message model.
//

import Foundation

struct CLIMessage: Identifiable, Codable, Hashable {
    let id: String
    let role: Role
    let content: [ContentBlock]
    let timestamp: Date
    var toolUse: [ToolUse]?
    var rawMessageId: String? = nil
    var rawSeq: Int? = nil
    var runId: String? = nil
    var parentRunId: String? = nil
    var isSidechain: Bool = false
    var selectedSkillName: String? = nil
    var selectedSkillUri: String? = nil

    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    struct ContentBlock: Codable, Hashable {
        let type: ContentType
        let text: String?
        let toolUseId: String?
        let toolName: String?
        let toolInput: [String: String]?
        let uuid: String?
        let parentUUID: String?

        enum ContentType: String, Codable {
            case text
            case thinking
            case toolUse = "tool_use"
            case toolResult = "tool_result"
            case event
        }
    }

    struct ToolUse: Codable, Hashable {
        let id: String
        var name: String
        var input: String?
        var output: String?
        var inputPayloadRef: String?
        var outputPayloadRef: String?
        var inputPayloadSize: Int?
        var outputPayloadSize: Int?
        var status: Status = .pending
        var executionTime: Double?
        var description: String?
        var permission: Permission?

        enum Status: String, Codable {
            case pending
            case running
            case success
            case error
        }

        struct Permission: Codable, Hashable {
            let id: String
            var status: PermissionStatus
            var reason: String?
            var mode: String?
            var allowedTools: [String]?
            var decision: String?
            var date: Double?

            enum PermissionStatus: String, Codable {
                case pending
                case approved
                case denied
                case canceled
            }
        }

        // Legacy support - convert from dict format if needed
        init(
            id: String,
            name: String,
            input: String?,
            output: String? = nil,
            inputPayloadRef: String? = nil,
            outputPayloadRef: String? = nil,
            inputPayloadSize: Int? = nil,
            outputPayloadSize: Int? = nil,
            status: Status = .pending,
            executionTime: Double? = nil,
            description: String? = nil,
            permission: Permission? = nil
        ) {
            self.id = id
            self.name = name
            self.input = input
            self.output = output
            self.inputPayloadRef = inputPayloadRef
            self.outputPayloadRef = outputPayloadRef
            self.inputPayloadSize = inputPayloadSize
            self.outputPayloadSize = outputPayloadSize
            self.status = status
            self.executionTime = executionTime
            self.description = description
            self.permission = permission
        }

        // Support legacy dict-based input
        init(id: String, name: String, inputDict: [String: String], result: String? = nil) {
            self.id = id
            self.name = name
            // Flatten dict to string
            self.input = inputDict.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
            self.output = result
            self.inputPayloadRef = nil
            self.outputPayloadRef = nil
            self.inputPayloadSize = nil
            self.outputPayloadSize = nil
            self.status = result != nil ? .success : .pending
            self.executionTime = nil
            self.description = nil
            self.permission = nil
        }
    }

    // Computed properties
    var displayText: String {
        content
            .filter { $0.type == .text }
            .compactMap { $0.text }
            .joined(separator: "\n")
    }

    var hasToolUse: Bool {
        content.contains { $0.type == .toolUse }
    }
}

// MARK: - Sample Data
extension CLIMessage {
    static let sampleUser = CLIMessage(
        id: UUID().uuidString,
        role: .user,
        content: [ContentBlock(type: .text, text: "帮我写个函数", toolUseId: nil, toolName: nil, toolInput: nil, uuid: nil, parentUUID: nil)],
        timestamp: Date()
    )

    static let sampleAssistant = CLIMessage(
        id: UUID().uuidString,
        role: .assistant,
        content: [ContentBlock(type: .text, text: "好的,我来帮你写一个函数...", toolUseId: nil, toolName: nil, toolInput: nil, uuid: nil, parentUUID: nil)],
        timestamp: Date()
    )
}

enum CLIToolCardKind {
    case reasoning
    case command
    case fileEdit
    case webSearch
    case read
    case glob
    case todo
    case task
    case backgroundTask
    case sessionControl
    case parallelDispatch
    case titleChange
    case protocolFallback
    case generic
}

/// Preferred semantic name: this represents ACP event rendering kinds in CLI UI.
typealias CLIAcpEventRenderKind = CLIToolCardKind

// Shared protocol semantics for realtime parse, replay decode and UI render.
// Keep all name-to-card mapping in one place to avoid per-view hard-coded matching drift.
enum CLIToolSemantics {
    private static func isBackgroundTaskNameNormalized(_ key: String) -> Bool {
        key == "backgroundtask"
            || key == "background_task"
            || key == "background-task"
            || (hasToken("background", in: key) && hasToken("task", in: key))
    }

    private static func isBackgroundTaskEventNameNormalized(_ key: String) -> Bool {
        if isBackgroundTaskNameNormalized(key) {
            return true
        }
        return key == "background_output"
            || key == "background-output"
            || key == "backgroundoutput"
            || key == "background_cancel"
            || key == "background-cancel"
            || key == "backgroundcancel"
            || key.hasPrefix("background_")
            || key.hasPrefix("background-")
    }

    private static func isTaskNameNormalized(_ key: String) -> Bool {
        if isBackgroundTaskNameNormalized(key) { return false }
        return key == "task"
            || key.hasPrefix("task")
            || key.contains("subagent")
    }

    static func normalizedKey(_ name: String?) -> String {
        (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func canonicalToolName(_ rawName: String) -> String {
        switch classifyToolName(rawName) {
        case .parallelDispatch:
            return "ParallelToolUse"
        case .reasoning:
            return "Reasoning"
        case .command:
            return "Bash"
        case .fileEdit:
            return "FileEdit"
        case .read:
            return "Read"
        case .glob:
            return "Glob"
        case .todo:
            return "TodoWrite"
        case .task:
            return "Task"
        case .backgroundTask:
            return "BackgroundTask"
        case .sessionControl:
            return "SessionControl"
        case .webSearch:
            return "WebSearch"
        case .titleChange:
            return "ChangeTitle"
        case .protocolFallback, .generic:
            return rawName
        }
    }

    static func classifyToolName(_ name: String?) -> CLIToolCardKind {
        let key = normalizedKey(name)
        if key.isEmpty { return .generic }

        if isProtocolFallbackName(key) { return .protocolFallback }
        if isParallelDispatchName(key) { return .parallelDispatch }
        if isReasoningName(key) { return .reasoning }
        if isTitleChangeName(key) { return .titleChange }
        if isTodoName(key) { return .todo }
        if isBackgroundTaskEventName(key) || isBackgroundTaskName(key) { return .backgroundTask }
        if isSessionControlName(key) { return .sessionControl }
        if isTaskName(key) { return .task }
        if isWebSearchName(key) { return .webSearch }
        if isReadName(key) { return .read }
        if isGlobName(key) { return .glob }
        if isFileEditName(key) { return .fileEdit }
        if isCommandLikeName(key) { return .command }
        return .generic
    }

    static func classifyAcpEventKind(_ name: String?) -> CLIAcpEventRenderKind {
        classifyToolName(name)
    }

    static func isInternalName(_ name: String?) -> Bool {
        normalizedKey(name) == "codexdiff"
    }

    static func isProtocolFallbackName(_ name: String?) -> Bool {
        normalizedKey(name).hasPrefix("protocol.")
    }

    static func isReasoningName(_ name: String?) -> Bool {
        hasToken("reason", in: name) || normalizedKey(name).contains("reason")
    }

    static func isCommandLikeName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        return hasToken("bash", in: key)
            || key.contains("bash")
            || hasToken("command", in: key)
            || hasToken("shell", in: key)
            || hasToken("execute", in: key)
            || hasToken("exec", in: key)
            || key == "sh"
            || key.hasSuffix(".sh")
            || key.contains("zsh")
            || key.contains("powershell")
    }

    static func isFileEditName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        guard !key.isEmpty else { return false }

        if key == "fileedit"
            || key == "file_edit"
            || key == "file-edit"
            || key == "fs-edit"
            || key == "fs_edit"
            || key == "fsedit"
            || key == "patch"
            || key.contains("filechange")
            || key.contains("file_change")
            || key.contains("file-change")
            || key.contains("patch_apply")
            || key.contains("apply_patch")
            || key.contains("patchapply")
            || key.contains("codexpatch")
            || key.contains("geminipatch")
            || key.contains("opencodepatch")
            || key == "edit"
            || key == "write"
            || key == "multiedit"
            || key == "notebookedit"
            || key.hasSuffix("_edit")
            || key.hasSuffix("-edit")
            || key.hasSuffix(".edit")
            || key.hasSuffix("_write")
            || key.hasSuffix("-write")
            || key.hasSuffix(".write") {
            return true
        }

        if hasToken("patch", in: key)
            || hasToken("edit", in: key)
            || hasToken("write", in: key) {
            return true
        }

        return false
    }

    static func isWebSearchName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        return key.contains("websearch")
            || key.contains("web_search")
            || key.contains("web-search")
    }

    static func isReadName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        return key == "read"
            || hasToken("read", in: key)
            || key.hasSuffix(".read")
            || key.hasSuffix("_read")
            || key.hasSuffix("-read")
    }

    static func isGlobName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        return key == "glob"
            || key == "globtool"
            || hasToken("glob", in: key)
    }

    static func isSearchLikeName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        return hasToken("search", in: key)
            || hasToken("grep", in: key)
            || hasToken("glob", in: key)
            || hasToken("find", in: key)
    }

    static func isTitleChangeName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        return key.contains("cgo_change_title")
            || key.contains("change_title")
            || key.contains("changetitle")
    }

    static func isTodoName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        return key == "todo"
            || key == "todowrite"
            || key == "todo_write"
            || key == "todoread"
            || key == "todo_read"
            || key.contains("todo")
    }

    static func isBackgroundTaskName(_ name: String?) -> Bool {
        isBackgroundTaskNameNormalized(normalizedKey(name))
    }

    static func isBackgroundTaskEventName(_ name: String?) -> Bool {
        isBackgroundTaskEventNameNormalized(normalizedKey(name))
    }

    static func isTaskName(_ name: String?) -> Bool {
        isTaskNameNormalized(normalizedKey(name))
    }

    static func isTaskLikeName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        return isTaskNameNormalized(key)
            || isBackgroundTaskNameNormalized(key)
            || isBackgroundTaskEventNameNormalized(key)
    }

    static func isSessionControlName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        guard !key.isEmpty else { return false }
        return key == "sessionmode"
            || key == "sessionavailablecommands"
            || key == "sessionconfigoptions"
            || key == "session.mode"
            || key == "session.available.commands"
            || key == "session.config.options"
            || key == "current.mode.update"
            || key == "available.commands.update"
            || key == "config.option.update"
    }

    static func isParallelDispatchName(_ name: String?) -> Bool {
        let key = normalizedKey(name)
        guard key.contains("parallel") else { return false }
        if key == "parallel_dispatch"
            || key == "parallel-dispatch"
            || key == "parallel.dispatch"
            || key == "paralleldispatch"
            || key == "parallel_tool_use"
            || key == "parallel-tool-use"
            || key == "parallel.tool.use" {
            return true
        }
        return key.contains("paralleltooluse")
            || key.contains("multi_tool_use")
            || key.contains("multi-tool-use")
            || key.contains("multi.tool.use")
            || key.contains("tool_use")
            || key.contains("tool-use")
            || key.contains("tool.use")
            || key.contains("tooluse")
            || key.contains("use.parallel")
    }

    static func hasToken(_ token: String, in name: String?) -> Bool {
        let key = normalizedKey(name)
        guard !key.isEmpty else { return false }
        if key == token {
            return true
        }

        // Fast token matching without regex compilation on the render hot path.
        // Tool identifiers in this app are separator-delimited words.
        var segmentStart = key.startIndex
        var cursor = key.startIndex
        while cursor < key.endIndex {
            let char = key[cursor]
            let isSeparator = (char == ".")
                || (char == "_")
                || (char == ":")
                || (char == "/")
                || (char == "-")
            if isSeparator {
                if segmentStart < cursor {
                    let segment = key[segmentStart..<cursor]
                    if segment == token {
                        return true
                    }
                }
                segmentStart = key.index(after: cursor)
            }
            cursor = key.index(after: cursor)
        }

        if segmentStart < key.endIndex {
            let segment = key[segmentStart..<key.endIndex]
            if segment == token {
                return true
            }
        }

        return false
    }
}
