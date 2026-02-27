//
//  SpaceSelectionSheet.swift
//  contextgo
//
//  Space 选择器弹窗，用于选择要连接的 spaces
//

import SwiftUI

struct SpaceSelectionSheet: View {
    @Binding var selectedSpaceIds: Set<String>
    @Binding var isContextGoEnabled: Bool
    let availableSpaces: [Space]
    let onConfirm: () -> Void
    let onClose: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // Header with master toggle
                VStack(spacing: 16) {
                    Toggle(isOn: $isContextGoEnabled) {
                        HStack(spacing: 12) {
                            Image(systemName: "network")
                                .font(.title2)
                                .foregroundColor(isContextGoEnabled ? .green : .gray)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("连接 ContextGO")
                                    .font(.headline)
                                    .foregroundColor(.primary)

                                Text(isContextGoEnabled ? "已启用上下文增强" : "点击启用上下文增强")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .tint(.green)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(colorScheme == .dark ? Color(.systemGray6).opacity(0.5) : Color(.systemGray6))
                    )
                }
                .padding()

                // Space list (only show when enabled)
                if isContextGoEnabled {
                    ScrollView {
                        VStack(spacing: 12) {
                            ForEach(availableSpaces) { space in
                                SpaceSelectionRow(
                                    space: space,
                                    isSelected: selectedSpaceIds.contains(space.id),
                                    onToggle: {
                                        if selectedSpaceIds.contains(space.id) {
                                            selectedSpaceIds.remove(space.id)
                                        } else {
                                            selectedSpaceIds.insert(space.id)
                                        }
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                    .scrollIndicators(.hidden)
                } else {
                    Spacer()
                    VStack(spacing: 16) {
                        Image(systemName: "network.slash")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)

                        Text("ContextGO 已禁用")
                            .font(.headline)
                            .foregroundColor(.secondary)

                        Text("启用后可以连接空间，增强对话上下文")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                }
            }
            .navigationTitle("空间选择")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        onClose()
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("确认") {
                        onConfirm()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Space Selection Row

struct SpaceSelectionRow: View {
    let space: Space
    let isSelected: Bool
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 12) {
                // Selection indicator
                ZStack {
                    Circle()
                        .strokeBorder(isSelected ? Color.blue : Color.gray.opacity(0.3), lineWidth: 2)
                        .frame(width: 24, height: 24)

                    if isSelected {
                        Circle()
                            .fill(Color.blue)
                            .frame(width: 16, height: 16)
                    }
                }

                // Space info
                VStack(alignment: .leading, spacing: 4) {
                    Text(space.displayName)
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text("\(space.taskCount) tasks • \(space.contextCount) contexts")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(colorScheme == .dark ? Color(.systemGray6).opacity(0.3) : Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.blue.opacity(0.5) : Color.clear,
                        lineWidth: 2
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SpaceSelectionSheet(
        selectedSpaceIds: .constant(["1"]),
        isContextGoEnabled: .constant(true),
        availableSpaces: [
            Space(id: "1", name: nil, displayName: "Default Space", description: nil, createdAt: "2026-01-01", lastActiveAt: nil, contextCount: 12, taskCount: 3, storageUsed: 0),
            Space(id: "2", name: nil, displayName: "Work", description: nil, createdAt: "2026-01-02", lastActiveAt: nil, contextCount: 8, taskCount: 2, storageUsed: 0),
            Space(id: "3", name: nil, displayName: "Personal", description: nil, createdAt: "2026-01-03", lastActiveAt: nil, contextCount: 5, taskCount: 1, storageUsed: 0)
        ],
        onConfirm: { print("Confirmed") },
        onClose: { print("Closed") }
    )
}
