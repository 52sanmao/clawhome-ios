import Foundation

enum AgentChannelType: String, Codable {
    case openClaw = "OpenClaw"
    case claudeCode = "Claude Code"
    case codex = "Codex"
    case openCode = "OpenCode"
    case geminiCLI = "Gemini CLI"

    var displayName: String { rawValue }

    var logoName: String {
        switch self {
        case .openClaw: return "OpenClawLogo"
        case .claudeCode: return "ClaudeCodeLogo"
        case .codex: return "CodexLogo"
        case .openCode: return "OpenCodeLogo"
        case .geminiCLI: return "GeminiCliLogo"
        }
    }

    var isOpenClaw: Bool {
        self == .openClaw
    }
}

extension CloudAgent {
    var uiDisplayName: String {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return name
    }

    var normalizedAgentType: String {
        type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "-", with: "")
    }

    var channelType: AgentChannelType {
        switch normalizedAgentType {
        case "claudecode", "claude":
            return .claudeCode
        case "codex":
            return .codex
        case "opencode":
            return .openCode
        case "geminicli", "gemini":
            return .geminiCLI
        default:
            return .openClaw
        }
    }
}
