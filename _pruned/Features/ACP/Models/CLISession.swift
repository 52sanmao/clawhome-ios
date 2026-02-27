//
//  CLISession.swift
//  contextgo
//
//  CLI relay session model.
//

import Foundation

struct CLISession: Identifiable, Codable, Hashable {
    let id: String
    var seq: Int
    let createdAt: Date
    var updatedAt: Date
    var active: Bool
    var activeAt: Date

    // Metadata
    var metadata: Metadata?

    // Agent state
    var agentState: AgentState?
    var agentStateVersion: Int

    // Presence
    var presence: PresenceState {
        if active {
            return .online
        } else {
            return .offline(lastSeen: activeAt)
        }
    }

    // Computed properties
    var displayName: String {
        metadata?.customTitle ?? metadata?.summary?.text ?? metadata?.pathBasename ?? "Unnamed Session"
    }

    var displayPath: String {
        let path = metadata?.displayPath ?? metadata?.path ?? "/"
        return truncateMiddlePath(path, maxLength: 50)
    }

    /// Truncate path in the middle to ensure first and last components are visible
    /// Example: ~/very/long/path/to/project -> ~/very/.../to/project
    private func truncateMiddlePath(_ path: String, maxLength: Int) -> String {
        guard path.count > maxLength else {
            return path
        }

        // Split path into components
        let components = path.split(separator: "/").map(String.init)
        guard components.count > 2 else {
            // If only 1-2 components, just truncate at the end
            return String(path.prefix(maxLength - 3)) + "..."
        }

        // Always keep first and last component
        let first = components.first!
        let last = components.last!

        // Try to include as many middle components as possible
        var result = first + "/"
        var availableLength = maxLength - first.count - last.count - 5  // Reserve space for "/.../" and last

        var middleComponents: [String] = []

        // Add components from the second one
        for i in 1..<(components.count - 1) {
            let component = components[i]
            let componentWithSlash = component + "/"

            if availableLength >= componentWithSlash.count {
                middleComponents.append(component)
                availableLength -= componentWithSlash.count
            } else {
                // No more space, break
                break
            }
        }

        // Build final path
        if middleComponents.isEmpty {
            // Can't fit any middle components
            result = first + "/.../" + last
        } else {
            result = first + "/" + middleComponents.joined(separator: "/") + "/.../" + last
        }

        return result
    }

    var machineName: String {
        metadata?.host ?? "Unknown"
    }

    var isThinking: Bool {
        agentState?.status == .thinking
    }

    // MARK: - Nested Types

    struct Metadata: Codable, Hashable {
        let path: String
        let host: String
        let machineId: String
        let hostPid: Int?
        let flavor: String?  // "claude", "codex", "gemini"
        let homeDir: String
        let version: String  // CLI version
        let platform: String?
        var runtime: Runtime? = nil
        let claudeSessionId: String?
        let codexSessionId: String?
        let opencodeSessionId: String?
        let geminiSessionId: String?
        let customTitle: String?
        var summary: Summary?
        var gitStatus: GitStatus?

        var displayPath: String {
            // Convert absolute path to relative from home
            if path.hasPrefix(homeDir) {
                let relative = String(path.dropFirst(homeDir.count))
                return "~\(relative)"
            }
            return path
        }

        var pathBasename: String {
            URL(fileURLWithPath: path).lastPathComponent
        }

        struct Summary: Codable, Hashable {
            let text: String
            let updatedAt: Date
        }

        struct GitStatus: Codable, Hashable {
            let branch: String?
            let isDirty: Bool?
            let changedFiles: Int?
            let addedLines: Int?
            let deletedLines: Int?
            let upstreamBranch: String?
            let aheadCount: Int?
            let behindCount: Int?
        }

        struct Runtime: Codable, Hashable {
            struct Skill: Codable, Hashable {
                let skillUri: String
                let name: String?
                let description: String?
                let scope: String?
                let type: String?
                let spaceId: String?
                let isSystem: Bool?
                let isLoaded: Bool?
                let lastLoadedAt: Date?
            }

            let provider: String?
            let agentVersion: String?
            let status: String?
            let statusDetail: String?
            let permissionMode: String?
            let permissionModeLabel: String?
            let reasoningEffort: String?
            let reasoningEffortLabel: String?
            let supportedReasoningEfforts: [String]?
            let opencodeModeId: String?
            let opencodeModeLabel: String?
            let opencodeModelId: String?
            let opencodeVariant: String?
            let opencodeAvailableVariants: [String]?
            let model: String?
            let contextSize: Int?
            let contextWindow: Int?
            let contextRemainingPercent: Double?
            let mcpReady: [String]?
            let mcpFailed: [String]?
            let mcpCancelled: [String]?
            let mcpToolNames: [String]?
            let mcpStartupPhase: String?
            let mcpStartupUpdatedAt: Date?
            let skillAvailableCount: Int?
            let skillLoadedCount: Int?
            let skillLoadedUris: [String]?
            let skillLoadState: String?
            let skillLastSyncAt: Date?
            let skillLastError: String?
            let skills: [Skill]?
            let updatedAt: Date?
            let titleStatus: String?
            let titleSource: String?
            let titleUpdatedAt: Date?
            let titleLastError: String?
        }
    }

    struct AgentState: Codable, Hashable {
        let status: Status
        let message: String?
        let requests: [String: PermissionRequest]?
        let completedRequests: [String: CompletedPermissionRequest]?

        enum Status: String, Codable {
            case idle
            case thinking
            case waitingForPermission = "waiting_for_permission"
            case error
        }

        struct PermissionRequest: Codable, Hashable {
            let tool: String
            let arguments: String?
            let createdAt: Date?
        }

        struct CompletedPermissionRequest: Codable, Hashable {
            let tool: String
            let arguments: String?
            let createdAt: Date?
            let completedAt: Date?
            let status: String
            let reason: String?
            let mode: String?
            let allowedTools: [String]?
            let decision: String?
        }
    }

    enum PresenceState: Hashable {
        case online
        case offline(lastSeen: Date)

        var isOnline: Bool {
            if case .online = self {
                return true
            }
            return false
        }

        var lastSeenText: String? {
            if case .offline(let date) = self {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .short
                return formatter.localizedString(for: date, relativeTo: Date())
            }
            return nil
        }
    }
}

// MARK: - Session Status
extension CLISession {
    /// Computed session status based on presence and agent state
    var sessionStatus: SessionStatus {
        // 1. Check if offline
        if !presence.isOnline {
            return .disconnected
        }

        // 2. Check agent state
        if let agentState = agentState {
            switch agentState.status {
            case .thinking:
                return .thinking
            case .waitingForPermission:
                return .permissionRequired
            case .error:
                return .error
            case .idle:
                return .waiting
            }
        }

        // 3. Default to waiting (online but no agent state)
        return .waiting
    }

    enum SessionStatus {
        case disconnected
        case thinking
        case waiting
        case permissionRequired
        case error

        var color: String {
            switch self {
            case .disconnected: return "#999999"  // Gray
            case .thinking: return "#007AFF"       // Blue
            case .waiting: return "#34C759"        // Green
            case .permissionRequired: return "#FF9500"  // Orange
            case .error: return "#FF3B30"          // Red
            }
        }

        var text: String {
            switch self {
            case .disconnected: return "离线"
            case .thinking: return "思考中"
            case .waiting: return "在线"
            case .permissionRequired: return "需要权限"
            case .error: return "错误"
            }
        }

        var isPulsing: Bool {
            self == .thinking || self == .permissionRequired
        }

        var icon: String {
            switch self {
            case .disconnected: return "circle.fill"
            case .thinking: return "brain"
            case .waiting: return "checkmark.circle.fill"
            case .permissionRequired: return "exclamationmark.triangle.fill"
            case .error: return "xmark.circle.fill"
            }
        }
    }
}

// MARK: - Sample Data
extension CLISession {
    static let sample = CLISession(
        id: "session-1",
        seq: 1,
        createdAt: Date(),
        updatedAt: Date(),
        active: true,
        activeAt: Date(),
        metadata: Metadata(
            path: "/Users/user/projects/myapp",
            host: "MacBook Pro",
            machineId: "machine-1",
            hostPid: 12345,
            flavor: "claude",
            homeDir: "/Users/user",
            version: "0.14.0",
            platform: "darwin",
            claudeSessionId: "claude-session-1",
            codexSessionId: nil,
            opencodeSessionId: nil,
            geminiSessionId: nil,
            customTitle: nil,
            summary: Metadata.Summary(text: "My App", updatedAt: Date()),
            gitStatus: Metadata.GitStatus(
                branch: "main",
                isDirty: false,
                changedFiles: 3,
                addedLines: 128,
                deletedLines: 41,
                upstreamBranch: "origin/main",
                aheadCount: 2,
                behindCount: 0
            )
        ),
        agentState: nil,
        agentStateVersion: 0
    )
}
