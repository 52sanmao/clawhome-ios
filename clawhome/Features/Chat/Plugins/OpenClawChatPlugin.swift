//
//  OpenClawChatPlugin.swift
//  contextgo
//
//  IronClaw chat plugin adapter for ChatViewModel.
//

import Foundation

@MainActor
final class OpenClawChatPlugin: ChatAgentPlugin {
    let id: String = "openclaw"
    let toolbarCapabilities = ChatToolbarCapabilities(
        showsSkills: false,
        showsUsageStats: true,
        showsCronJobs: true,
        showsSettings: false,
        showsThinkingControl: false
    )

    func bind(client: OpenClawClient, viewModel: ChatViewModel) {
        unbind(client: client)

        client.onAgentStreamDelta = { [weak viewModel] delta in
            Self.dispatch(event: .streamDelta(delta), to: viewModel)
        }

        client.onAgentThinkingDelta = { [weak viewModel] thinking in
            Self.dispatch(event: .thinkingDelta(thinking), to: viewModel)
        }

        client.onAgentComplete = { [weak viewModel] in
            Self.dispatch(event: .streamComplete, to: viewModel)
        }

        client.onAgentError = { [weak viewModel] error in
            Self.dispatch(event: .streamError(error), to: viewModel)
        }

        client.onRunAccepted = { [weak viewModel] runId in
            Self.dispatch(event: .runAccepted(runId), to: viewModel)
        }

        client.onChatStateEvent = { [weak viewModel] event in
            Self.dispatch(event: .chatState(event), to: viewModel)
        }

        client.onOtherChannelActivity = { [weak viewModel] channels, isActive in
            Self.dispatch(event: .otherChannelActivity(channels: channels, isActive: isActive), to: viewModel)
        }

        client.onToolExecutionStart = { [weak viewModel] runId, toolId, toolName, input in
            Self.dispatch(
                event: .toolStart(runId: runId, toolId: toolId, toolName: toolName, input: input),
                to: viewModel
            )
        }

        client.onToolExecutionUpdate = { [weak viewModel] runId, toolId, partialOutput in
            Self.dispatch(
                event: .toolUpdate(runId: runId, toolId: toolId, partialOutput: partialOutput),
                to: viewModel
            )
        }

        client.onToolExecutionResult = { [weak viewModel] runId, toolId, output, error in
            Self.dispatch(
                event: .toolResult(runId: runId, toolId: toolId, output: output, error: error),
                to: viewModel
            )
        }

        client.onLifecycleStart = { [weak viewModel] runId in
            Self.dispatch(event: .lifecycleStart(runId: runId), to: viewModel)
        }

        client.onLifecycleEnd = { [weak viewModel] runId in
            Self.dispatch(event: .lifecycleEnd(runId: runId), to: viewModel)
        }

        client.onLifecycleError = { [weak viewModel] runId, error in
            Self.dispatch(event: .lifecycleError(runId: runId, error: error), to: viewModel)
        }

        client.onCompactionEvent = { [weak viewModel] event in
            Self.dispatch(event: .compaction(event), to: viewModel)
        }

        client.onRunQueueChanged = { [weak viewModel] hasActiveRuns in
            Self.dispatch(event: .runQueueChanged(hasActiveRuns), to: viewModel)
        }
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

    private static func dispatch(event: ChatAgentPluginEvent, to viewModel: ChatViewModel?) {
        DispatchQueue.main.async {
            viewModel?.handlePluginEvent(event)
        }
    }
}
