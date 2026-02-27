//
//  ChatAgentPlugin.swift
//  contextgo
//
//  Chat agent plugin abstractions for callback binding and UI capabilities.
//

import Foundation

struct ChatToolbarCapabilities {
    let showsSkills: Bool
    let showsUsageStats: Bool
    let showsCronJobs: Bool
    let showsSettings: Bool
    let showsThinkingControl: Bool

    static let none = ChatToolbarCapabilities(
        showsSkills: false,
        showsUsageStats: false,
        showsCronJobs: false,
        showsSettings: false,
        showsThinkingControl: false
    )
}

enum ChatAgentPluginEvent {
    case streamDelta(String)
    case thinkingDelta(String)
    case streamComplete
    case streamError(String)
    case runAccepted(String)
    case chatState(OpenClawClient.ChatStateEvent)
    case otherChannelActivity(channels: Set<String>, isActive: Bool)
    case toolStart(runId: String, toolId: String, toolName: String, input: String?)
    case toolUpdate(runId: String, toolId: String, partialOutput: String)
    case toolResult(runId: String, toolId: String, output: String?, error: String?)
    case lifecycleStart(runId: String)
    case lifecycleEnd(runId: String)
    case lifecycleError(runId: String, error: String)
    case compaction(OpenClawClient.CompactionEvent)
    case runQueueChanged(Bool)
}

@MainActor
protocol ChatAgentPlugin {
    var id: String { get }
    var toolbarCapabilities: ChatToolbarCapabilities { get }
    func bind(client: OpenClawClient, viewModel: ChatViewModel)
    func unbind(client: OpenClawClient)
}

@MainActor
enum ChatAgentPluginRegistry {
    static func resolve(agent: CloudAgent?) -> ChatAgentPlugin {
        guard let agent else {
            return OpenClawChatPlugin()
        }
        switch agent.channelType {
        case .openClaw:
            return OpenClawChatPlugin()
        case .claudeCode, .codex, .openCode, .geminiCLI:
            return PassthroughChatAgentPlugin()
        }
    }
}

@MainActor
final class PassthroughChatAgentPlugin: ChatAgentPlugin {
    let id: String = "passthrough"
    let toolbarCapabilities: ChatToolbarCapabilities = .none

    func bind(client _: OpenClawClient, viewModel _: ChatViewModel) {
        // No-op: this plugin intentionally does not bind any OpenClaw callbacks.
    }

    func unbind(client: OpenClawClient) {
        client.onAgentStreamDelta = nil
        client.onAgentThinkingDelta = nil
        client.onAgentComplete = nil
        client.onAgentError = nil
        client.onRunAccepted = nil
        client.onChatStateEvent = nil
        client.onOtherChannelActivity = nil
        client.onToolExecutionStart = nil
        client.onToolExecutionUpdate = nil
        client.onToolExecutionResult = nil
        client.onLifecycleStart = nil
        client.onLifecycleEnd = nil
        client.onLifecycleError = nil
        client.onCompactionEvent = nil
        client.onMemoryCompaction = nil
        client.onRunQueueChanged = nil
    }
}
