import SwiftUI

struct OpenCodeRunGroupView: View {
    let group: CLIRunGroup
    let hasActiveRun: Bool
    let isLatestGroup: Bool
    let permissionActionInFlight: Set<String>
    let onAllowPermission: (String) -> Void
    let onAllowPermissionForSession: (String) -> Void
    let onDenyPermission: (String) -> Void

    private var shouldShowTimestamp: Bool {
        !(hasActiveRun && isLatestGroup)
    }

    private var lifecycleProjection: OpenCodeToolLifecycleProjection {
        OpenCodeToolLifecycleReducer.project(
            mergedToolStateById: group.mergedToolStateById,
            latestToolMessageIndexById: group.latestToolMessageIndexById
        )
    }

    var body: some View {
        let projection = lifecycleProjection
        let renderableRuntimeMessages = runtimeMessagesToRender(using: projection)

        VStack(alignment: .leading, spacing: 10) {
            ForEach(renderableRuntimeMessages, id: \.message.id) { entry in
                CLIRuntimeMessageView(
                    message: entry.message,
                    messageIndex: entry.index,
                    latestToolMessageIndexById: group.latestToolMessageIndexById,
                    mergedToolStateById: projection.resolvedToolStateById,
                    suppressedToolIDs: projection.suppressedToolIDs,
                    toolCardRenderer: { tool in
                        let resolvedTool = projection.resolvedToolStateById[tool.id] ?? tool
                        return AnyView(
                            OpenCodeToolEventCard(
                                toolUse: resolvedTool,
                                isActionLoading: permissionActionInFlight.contains(resolvedTool.permission?.id ?? ""),
                                onAllow: { id in onAllowPermission(id) },
                                onAllowForSession: { id in onAllowPermissionForSession(id) },
                                onDeny: { id in onDenyPermission(id) }
                            )
                        )
                    }
                )
            }

            if shouldShowTimestamp,
               let timestamp = group.runtimeMessages.last?.timestamp {
                Text(timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 2)
    }

    private func runtimeMessagesToRender(
        using projection: OpenCodeToolLifecycleProjection
    ) -> [(index: Int, message: CLIMessage)] {
        Array(group.runtimeMessages.enumerated()).compactMap { index, message in
            if shouldRender(message: message, messageIndex: index, projection: projection) {
                return (index, message)
            }
            return nil
        }
    }

    private func shouldRender(
        message: CLIMessage,
        messageIndex: Int,
        projection: OpenCodeToolLifecycleProjection
    ) -> Bool {
        if shouldRenderTextContent(for: message) {
            return true
        }

        let hasVisibleTools = (message.toolUse ?? []).contains { tool in
            guard !projection.suppressedToolIDs.contains(tool.id) else { return false }
            return group.latestToolMessageIndexById[tool.id] == messageIndex
        }
        return hasVisibleTools
    }

    private func shouldRenderTextContent(for message: CLIMessage) -> Bool {
        if message.role == .user {
            return !message.displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return message.content.contains { block in
            guard block.type == .text else { return false }
            guard let text = block.text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !text.isEmpty
        }
    }
}
