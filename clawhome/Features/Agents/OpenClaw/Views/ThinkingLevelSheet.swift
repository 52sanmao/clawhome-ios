//
//  ThinkingLevelSheet.swift
//  contextgo
//
//  OpenClaw 思考等级控制 - 半屏 Sheet
//  通过 sessions.patch RPC 更新当前 Session 的思考深度
//

import SwiftUI

struct ThinkingLevelSheet: View {
    let client: OpenClawClient
    let sessionKey: String
    let initialLevel: String?
    var onApplied: ((String) -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedLevel: ThinkingLevel = .medium
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var didSave = false

    init(client: OpenClawClient, sessionKey: String, initialLevel: String? = nil, onApplied: ((String) -> Void)? = nil) {
        self.client = client
        self.sessionKey = sessionKey
        self.initialLevel = initialLevel
        self.onApplied = onApplied
        _selectedLevel = State(initialValue: ThinkingLevel.from(raw: initialLevel))
    }

    var body: some View {
        NavigationView {
            ZStack {
                (colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    levelList

                    applyButton
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 20)
                }
            }
            .navigationTitle("思考等级")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
            .alert("设置失败", isPresented: .constant(errorMessage != nil)) {
                Button("确定") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .task {
            await refreshThinkingLevelFromIronClaw()
        }
    }

    // MARK: - Level List

    private var levelList: some View {
        ScrollView {
            VStack(spacing: 10) {
                ForEach(ThinkingLevel.allCases) { level in
                    LevelRow(
                        level: level,
                        isSelected: selectedLevel == level,
                        colorScheme: colorScheme
                    )
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            selectedLevel = level
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(colorScheme == .dark ? Color(.systemGray6).opacity(0.35) : Color(.systemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(
                                selectedLevel == level ? Color.accentColor.opacity(0.35) : Color.clear,
                                lineWidth: 1.5
                            )
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - Apply Button

    private var applyButton: some View {
        Button(action: applyLevel) {
            HStack {
                if isSaving {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                        .scaleEffect(0.85)
                } else if didSave {
                    Image(systemName: "checkmark")
                        .font(.system(size: 15, weight: .semibold))
                } else {
                    Text("应用")
                        .font(.system(size: 16, weight: .semibold))
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .background(isSaving ? Color.gray : Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(12)
        }
        .disabled(isSaving)
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func applyLevel() {
        isSaving = true
        errorMessage = nil
        Task {
            do {
                try await client.patchThinkingLevel(
                    sessionKey: sessionKey,
                    thinkingLevel: selectedLevel.rawValue
                )
                await MainActor.run {
                    isSaving = false
                    didSave = true
                    onApplied?(selectedLevel.rawValue)
                }
                try? await Task.sleep(nanoseconds: 600_000_000)
                await MainActor.run { dismiss() }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func refreshThinkingLevelFromIronClaw() async {
        do {
            let response = try await client.fetchChatHistory(sessionKey: sessionKey, limit: 1)
            guard let thinkingLevel = response.historyPayload?.thinkingLevel else {
                return
            }
            await MainActor.run {
                selectedLevel = ThinkingLevel.from(raw: thinkingLevel)
            }
        } catch {
            print("[ThinkingLevelSheet] Failed to refresh current level: \(error)")
        }
    }
}

// MARK: - Thinking Level Enum

enum ThinkingLevel: String, CaseIterable, Identifiable {
    case off     = "off"
    case minimal = "minimal"
    case low     = "low"
    case medium  = "medium"
    case high    = "high"
    case xhigh   = "xhigh"

    var id: String { rawValue }

    static func from(raw: String?) -> ThinkingLevel {
        guard let raw else { return .off }
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "off": return .off
        case "minimal", "min", "think": return .minimal
        case "low", "on", "enable", "enabled": return .low
        case "medium", "med", "mid": return .medium
        case "high", "max", "highest": return .high
        case "xhigh", "x-high", "x_high", "extrahigh", "extra-high", "extra high", "extra_high":
            return .xhigh
        default:
            return .off
        }
    }

    var displayName: String {
        switch self {
        case .off:     return "关闭"
        case .minimal: return "极简"
        case .low:     return "低"
        case .medium:  return "中"
        case .high:    return "高"
        case .xhigh:   return "超高"
        }
    }

    var shortDisplayName: String {
        switch self {
        case .off: return "关"
        case .minimal: return "极简"
        case .low: return "低"
        case .medium: return "中"
        case .high: return "高"
        case .xhigh: return "超高"
        }
    }

    var description: String {
        switch self {
        case .off:     return "直接回复，无内部推理，速度最快"
        case .minimal: return "仅做最基本的上下文检查"
        case .low:     return "简单的逻辑推理"
        case .medium:  return "平衡速度与深度，适合日常任务"
        case .high:    return "深度推理，适合复杂编程或分析"
        case .xhigh:   return "超深度推理，仅限推理模型（如 o1/o3）"
        }
    }

    var icon: String {
        switch self {
        case .off:     return "moon.fill"
        case .minimal: return "circle"
        case .low:     return "circle.lefthalf.filled"
        case .medium:  return "circle.fill"
        case .high:    return "brain"
        case .xhigh:   return "brain.filled.head.profile"
        }
    }

    var accentColor: Color {
        switch self {
        case .off:     return .secondary
        case .minimal: return .gray
        case .low:     return .blue.opacity(0.7)
        case .medium:  return .blue
        case .high:    return .purple
        case .xhigh:   return .orange
        }
    }
}

// MARK: - Level Row

private struct LevelRow: View {
    let level: ThinkingLevel
    let isSelected: Bool
    let colorScheme: ColorScheme

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: level.icon)
                .font(.system(size: 20))
                .foregroundColor(level.accentColor)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(level.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(colorScheme == .dark ? .white : .black)
                Text(level.description)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }
}
