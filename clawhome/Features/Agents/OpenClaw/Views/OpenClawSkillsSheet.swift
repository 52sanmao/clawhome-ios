//
//  OpenClawSkillsSheet.swift
//  contextgo
//
//  Skills list powered by OpenClaw Gateway RPC (skills.status / skills.update)
//

import SwiftUI

private enum SkillsGroupFilter: String, CaseIterable, Identifiable {
    case all
    case attention
    case enabled
    case disabled

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .attention: return "待处理"
        case .enabled: return "可用"
        case .disabled: return "已禁用"
        }
    }
}

struct OpenClawSkillsSheet: View {
    let client: OpenClawClient

    @Environment(\.dismiss) private var dismiss

    @State private var skills: [Skill] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var updatingSkillKeys: Set<String> = []
    @State private var isUpdatingAnySkill = false
    @State private var selectedFilter: SkillsGroupFilter = .all

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && skills.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在加载技能...")
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, skills.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.orange)
                        Text("技能列表加载失败")
                            .font(.system(size: 16, weight: .semibold))
                        Text(errorMessage)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                        Button("重试") {
                            Task { await loadSkills(showLoading: true) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                        if let errorMessage {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundColor(.orange)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.orange.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .padding(.horizontal, 16)
                        }

                        SkillsGroupTabStrip(
                            selectedFilter: selectedFilter,
                            counts: filterCounts,
                            onSelect: { selectedFilter = $0 }
                        )

                        if visibleGroups.isEmpty {
                            Text("当前分组暂无技能")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.vertical, 20)
                        } else {
                            ForEach(visibleGroups) { group in
                                if selectedFilter == .all {
                                    SkillSectionHeader(
                                        title: group.title,
                                        subtitle: group.subtitle
                                    )
                                    .padding(.horizontal, 16)
                                }

                                VStack(spacing: 0) {
                                    ForEach(Array(group.skills.enumerated()), id: \.element.id) { index, skill in
                                        SkillRow(
                                            skill: skill,
                                            isUpdating: updatingSkillKeys.contains(skill.skillKey),
                                            isInteractionLocked: isUpdatingAnySkill,
                                            onToggle: {
                                                Task { await toggleSkill(skill) }
                                            }
                                        )
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)

                                        if index < group.skills.count - 1 {
                                            Divider()
                                                .padding(.leading, 44)
                                        }
                                    }
                                }
                                .background(Color(.secondarySystemGroupedBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                    }
                    .scrollIndicators(.hidden)
                    .refreshable {
                        await loadSkills(showLoading: false)
                    }
                }
            }
            .navigationTitle("技能")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await loadSkills(showLoading: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
        }
        .task {
            await loadSkills(showLoading: true)
        }
    }

    private var sortedSkills: [Skill] {
        skills.sorted { lhs, rhs in
            if lhs.renderPriority != rhs.renderPriority {
                return lhs.renderPriority < rhs.renderPriority
            }
            return lhs.displayName.localizedCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var attentionSkills: [Skill] {
        sortedSkills.filter { $0.renderState == .blocked || $0.renderState == .needsSetup }
    }

    private var enabledSkills: [Skill] {
        sortedSkills.filter { $0.renderState == .enabled || $0.renderState == .alwaysOn }
    }

    private var disabledSkills: [Skill] {
        sortedSkills.filter { $0.renderState == .disabled }
    }

    private var sectionGroups: [SkillSectionGroup] {
        var groups: [SkillSectionGroup] = []

        if !attentionSkills.isEmpty {
            groups.append(
                SkillSectionGroup(
                    id: "attention",
                    title: "需要处理",
                    subtitle: "缺依赖、缺配置或被策略限制",
                    skills: attentionSkills
                )
            )
        }

        if !enabledSkills.isEmpty {
            groups.append(
                SkillSectionGroup(
                    id: "enabled",
                    title: "可用",
                    subtitle: "已可执行",
                    skills: enabledSkills
                )
            )
        }

        if !disabledSkills.isEmpty {
            groups.append(
                SkillSectionGroup(
                    id: "disabled",
                    title: "已禁用",
                    subtitle: "可重新启用",
                    skills: disabledSkills
                )
            )
        }

        return groups
    }

    private var filterCounts: [SkillsGroupFilter: Int] {
        [
            .all: skills.count,
            .attention: attentionSkills.count,
            .enabled: enabledSkills.count,
            .disabled: disabledSkills.count
        ]
    }

    private var visibleGroups: [SkillSectionGroup] {
        switch selectedFilter {
        case .all:
            return sectionGroups
        case .attention:
            return attentionSkills.isEmpty
                ? []
                : [SkillSectionGroup(id: "attention", title: "需要处理", subtitle: "缺依赖、缺配置或被策略限制", skills: attentionSkills)]
        case .enabled:
            return enabledSkills.isEmpty
                ? []
                : [SkillSectionGroup(id: "enabled", title: "可用", subtitle: "已可执行", skills: enabledSkills)]
        case .disabled:
            return disabledSkills.isEmpty
                ? []
                : [SkillSectionGroup(id: "disabled", title: "已禁用", subtitle: "可重新启用", skills: disabledSkills)]
        }
    }

    private func loadSkills(showLoading: Bool) async {
        if showLoading {
            isLoading = true
        }
        defer { isLoading = false }

        do {
            let fetched = try await client.fetchSkillsStatus()
            skills = fetched
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func toggleSkill(_ skill: Skill) async {
        guard skill.renderState == .enabled || skill.renderState == .disabled else { return }
        guard !updatingSkillKeys.contains(skill.skillKey) else { return }
        guard !isUpdatingAnySkill else { return }

        isUpdatingAnySkill = true
        updatingSkillKeys.insert(skill.skillKey)
        defer {
            updatingSkillKeys.remove(skill.skillKey)
            isUpdatingAnySkill = false
        }

        do {
            let shouldEnable = skill.disabled
            _ = try await client.updateSkill(skillKey: skill.skillKey, enabled: shouldEnable)
            await loadSkills(showLoading: false)
        } catch {
            if error.localizedDescription.contains("Not connected to ClawdBot") {
                errorMessage = "网关连接中断，正在自动重连，请稍后再试"
            } else {
            errorMessage = "更新技能状态失败：\(error.localizedDescription)"
            }
        }
    }
}

private struct SkillSectionGroup: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let skills: [Skill]
}

private struct SkillsGroupTabStrip: View {
    let selectedFilter: SkillsGroupFilter
    let counts: [SkillsGroupFilter: Int]
    let onSelect: (SkillsGroupFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(SkillsGroupFilter.allCases) { filter in
                    Button {
                        onSelect(filter)
                    } label: {
                        HStack(spacing: 6) {
                            Text(filter.title)
                                .font(.system(size: 12, weight: .semibold))
                            Text("\(counts[filter] ?? 0)")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .foregroundColor(selectedFilter == filter ? .white : .primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Capsule()
                                .fill(selectedFilter == filter ? Color.accentColor : Color(.systemGray5))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 2)
        }
    }
}

private struct SkillSectionHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .textCase(nil)
    }
}

private struct SkillRow: View {
    let skill: Skill
    let isUpdating: Bool
    let isInteractionLocked: Bool
    let onToggle: () -> Void

    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Text(skill.emoji ?? "🧩")
                    .font(.system(size: 20))

                VStack(alignment: .leading, spacing: 4) {
                    Text(skill.displayName)
                        .font(.system(size: 15, weight: .semibold))
                    Text(skill.description)
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(showDetails ? nil : 2)
                }

                Spacer()

                statusBadge
            }

            if let blockerSummary = skill.blockerSummary,
               skill.renderState == .blocked || skill.renderState == .needsSetup {
                Text(blockerSummary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.orange)
            }

            HStack(spacing: 8) {
                tagsLane
                Spacer(minLength: 0)
                if hasExpandableDetails {
                    detailsToggleButton
                }
                if showsTrailingAction {
                    trailingAction
                }
            }

            if showDetails {
                detailsPanel
            }
        }
        .padding(.vertical, 6)
    }

    private var tagsLane: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                tag(text: skill.sourceDisplayName, color: .secondary)

                if let primaryEnv = skill.primaryEnv, !primaryEnv.isEmpty {
                    tag(text: primaryEnv, color: .orange)
                }

                ForEach(skill.blockerTags, id: \.self) { item in
                    tag(text: item, color: .red)
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var showsTrailingAction: Bool {
        switch skill.renderState {
        case .enabled, .disabled:
            return true
        case .blocked, .alwaysOn, .needsSetup:
            return false
        }
    }

    private var hasExpandableDetails: Bool {
        !skill.filePath.isEmpty ||
        !skill.missingBinsList.isEmpty ||
        !skill.missingEnvList.isEmpty ||
        !skill.missingConfigList.isEmpty ||
        !skill.missingOSList.isEmpty ||
        !skill.installHints.isEmpty ||
        (skill.homepage?.isEmpty == false)
    }

    private var detailsToggleButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                showDetails.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Text(showDetails ? "收起" : "详情")
                    .font(.system(size: 11, weight: .semibold))
                Image(systemName: showDetails ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundColor(.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(Color(.systemGray5))
            )
        }
        .buttonStyle(.plain)
    }

    private func tag(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch skill.renderState {
        case .enabled, .disabled:
            Button(action: onToggle) {
                if isUpdating {
                    ProgressView()
                        .controlSize(.small)
                        .tint(skill.isEnabled ? .orange : .blue)
                        .frame(width: 32, height: 16)
                } else {
                    Text(skill.isEnabled ? "禁用" : "启用")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
            }
            .buttonStyle(.plain)
            .foregroundColor(skill.isEnabled ? .orange : .blue)
            .background(
                Capsule()
                    .fill((skill.isEnabled ? Color.orange : Color.blue).opacity(0.14))
            )
            .overlay(
                Capsule()
                    .stroke((skill.isEnabled ? Color.orange : Color.blue).opacity(0.35), lineWidth: 0.8)
            )
            .disabled(isUpdating || isInteractionLocked)

        case .blocked, .alwaysOn, .needsSetup:
            EmptyView()
        }
    }

    private var detailsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !skill.missingBinsList.isEmpty {
                detailOptionCardsLine(title: "缺少依赖", values: skill.missingBinsList)
            }
            if !skill.missingEnvList.isEmpty {
                detailLine(title: "缺少环境变量", values: skill.missingEnvList)
            }
            if !skill.missingConfigList.isEmpty {
                detailLine(title: "缺少配置项", values: skill.missingConfigList)
            }
            if !skill.missingOSList.isEmpty {
                detailLine(title: "系统要求", values: skill.missingOSList)
            }
            if !skill.installHints.isEmpty {
                detailLine(title: "安装提示", values: skill.installHints)
            }

            if !skill.filePath.isEmpty {
                Text(skill.filePath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }

            if let homepage = skill.homepage,
               let url = URL(string: homepage) {
                Link(destination: url) {
                    Text("打开技能主页")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detailOptionCardsLine(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120, maximum: 180), spacing: 6, alignment: .leading)],
                alignment: .leading,
                spacing: 6
            ) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                    Text(value)
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemFill))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
        }
    }

    private func detailLine(title: String, values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            Text(values.joined(separator: "、"))
                .font(.system(size: 12))
                .foregroundColor(.primary)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }

    private var statusBadge: some View {
        Text(skill.statusText)
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(statusColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(statusColor.opacity(0.12))
            .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch skill.renderState {
        case .enabled:
            return .green
        case .disabled:
            return .orange
        case .alwaysOn:
            return .cyan
        case .needsSetup:
            return .blue
        case .blocked:
            return .red
        }
    }
}
