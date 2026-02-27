//
//  SessionListView.swift
//  contextgo
//
//  CLI relay sessions list - pure native Swift flow
//

import SwiftUI

struct SessionListView: View {
    let agent: CloudAgent
    var onSelectSession: ((CLISession) -> Void)? = nil

    @StateObject private var viewModel: SessionListViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var showNewSessionSheet = false
    @State private var showAllInactiveSessions = false
    @State private var sessionPendingArchive: CLISession?
    @State private var sessionPendingDelete: CLISession?

    init(
        agent: CloudAgent,
        onSelectSession: ((CLISession) -> Void)? = nil
    ) {
        self.agent = agent
        self.onSelectSession = onSelectSession
        _viewModel = StateObject(wrappedValue: SessionListViewModel(agent: agent))
    }

    var body: some View {
        List {
            if activeSessions.isEmpty && inactiveSessions.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "terminal")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)

                    Text("暂无会话")
                        .font(.headline)

                    Text("本地缓存优先显示，远端增量会在后台自动同步")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 64)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                if !activeSessions.isEmpty {
                    Section {
                        ForEach(activeSessions) { session in
                            sessionRow(for: session, swipeAction: .archive)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    } header: {
                        sectionHeader(title: "活跃会话", count: activeSessions.count)
                    }
                }

                if !inactiveSessions.isEmpty {
                    Section {
                        ForEach(visibleInactiveSessions) { session in
                            sessionRow(for: session, swipeAction: .delete)
                                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }

                        if shouldShowInactiveCollapseToggle {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    showAllInactiveSessions.toggle()
                                }
                            } label: {
                                HStack {
                                    Spacer()
                                    Text(showAllInactiveSessions ? "收起不活跃会话" : "展开全部 \(inactiveSessions.count) 条不活跃会话")
                                        .font(.footnote.weight(.medium))
                                        .foregroundColor(.secondary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    } header: {
                        sectionHeader(title: "不活跃会话", count: inactiveSessions.count)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("会话列表")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    showNewSessionSheet = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
        }
        .sheet(isPresented: $showNewSessionSheet) {
            CLINewSessionSheet(
                agent: agent,
                client: viewModel.client,
                flavor: agentFlavor
            ) { created in
                onSelectSession?(created)
                dismiss()
            }
        }
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定", role: .cancel) { }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .alert(
            "归档会话",
            isPresented: Binding(
                get: { sessionPendingArchive != nil },
                set: { newValue in
                    if !newValue { sessionPendingArchive = nil }
                }
            )
        ) {
            Button("取消", role: .cancel) {
                sessionPendingArchive = nil
            }
            Button("归档") {
                guard let target = sessionPendingArchive else { return }
                sessionPendingArchive = nil
                Task {
                    await viewModel.archiveActiveSession(target)
                }
            }
        } message: {
            Text("归档后会话将停止通信，并移动到不活跃分组。")
        }
        .alert(
            "删除不活跃会话",
            isPresented: Binding(
                get: { sessionPendingDelete != nil },
                set: { newValue in
                    if !newValue { sessionPendingDelete = nil }
                }
            )
        ) {
            Button("取消", role: .cancel) {
                sessionPendingDelete = nil
            }
            Button("删除", role: .destructive) {
                guard let target = sessionPendingDelete else { return }
                sessionPendingDelete = nil
                Task {
                    await viewModel.deleteInactiveSession(target)
                }
            }
        } message: {
            Text("删除后将不再显示在该 Agent 会话列表中，且无法恢复。")
        }
        .refreshable {
            await viewModel.refresh()
        }
        .onAppear {
            viewModel.connect()
        }
    }

    private var agentFlavor: String {
        switch agent.type.lowercased() {
        case "codex":
            return "codex"
        case "geminicli":
            return "gemini"
        case "opencode":
            return "opencode"
        default:
            return "claude"
        }
    }

    private var activeSessions: [CLISession] {
        var seen = Set<String>()
        let sorted = viewModel.activeSessions.sorted { $0.updatedAt > $1.updatedAt }
        return sorted.filter { session in
            seen.insert(session.id).inserted
        }
    }

    private var inactiveSessions: [CLISession] {
        var seen = Set<String>()
        let sorted = viewModel.historicalSessions.sorted { $0.updatedAt > $1.updatedAt }
        return sorted.filter { session in
            seen.insert(session.id).inserted
        }
    }

    private var visibleInactiveSessions: [CLISession] {
        if showAllInactiveSessions || inactiveSessions.count <= 3 {
            return inactiveSessions
        }
        return Array(inactiveSessions.prefix(3))
    }

    private var shouldShowInactiveCollapseToggle: Bool {
        inactiveSessions.count > 3
    }

    @ViewBuilder
    private func sessionRow(for session: CLISession, swipeAction: SessionSwipeAction?) -> some View {
        if let swipeAction {
            SwipeRevealCardRow(
                cornerRadius: 14,
                revealWidth: 88,
                actionTitle: swipeAction.actionTitle,
                actionSystemImage: swipeAction.systemImage,
                actionColor: swipeAction.tint,
                actionRole: swipeAction.buttonRole,
                onAction: {
                    switch swipeAction {
                    case .archive:
                        sessionPendingArchive = session
                    case .delete:
                        sessionPendingDelete = session
                    }
                }
            ) {
                sessionTapControl(for: session, elevated: false)
            }
        } else {
            sessionTapControl(for: session, elevated: true)
        }
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(.secondary)
            Spacer()
            Text("\(count)")
                .font(.caption2.weight(.medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .textCase(nil)
    }

    @ViewBuilder
    private func sessionTapControl(for session: CLISession, elevated: Bool) -> some View {
        if let onSelectSession {
            Button {
                onSelectSession(session)
                dismiss()
            } label: {
                sessionCard(for: session, elevated: elevated)
            }
            .buttonStyle(.plain)
        } else {
            NavigationLink {
                SessionDetailView(session: session, client: viewModel.client)
            } label: {
                sessionCard(for: session, elevated: elevated)
            }
            .buttonStyle(.plain)
        }
    }

    private func sessionCard(for session: CLISession, elevated: Bool) -> some View {
        let shadowOpacity: Double = elevated ? (colorScheme == .dark ? 0.28 : 0.08) : 0
        let shadowRadius: CGFloat = elevated ? 8 : 0
        let shadowY: CGFloat = elevated ? 2 : 0

        return SessionListItem(session: session)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(colorScheme == .dark ? Color(.systemGray6) : Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.05)
                            : Color.black.opacity(0.05),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: shadowRadius,
                x: 0,
                y: shadowY
            )
    }

    private enum SessionSwipeAction {
        case archive
        case delete

        var actionTitle: String {
            switch self {
            case .archive:
                return "归档"
            case .delete:
                return "删除"
            }
        }

        var systemImage: String {
            switch self {
            case .archive:
                return "archivebox.fill"
            case .delete:
                return "trash.fill"
            }
        }

        var tint: Color {
            switch self {
            case .archive:
                return .orange
            case .delete:
                return .red
            }
        }

        var buttonRole: ButtonRole? {
            switch self {
            case .archive:
                return nil
            case .delete:
                return .destructive
            }
        }
    }
}

private struct SwipeRevealCardRow<Content: View>: View {
    let cornerRadius: CGFloat
    let revealWidth: CGFloat
    let actionTitle: String
    let actionSystemImage: String
    let actionColor: Color
    let actionRole: ButtonRole?
    let onAction: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var settledOffset: CGFloat = 0
    @GestureState private var dragTranslation: CGFloat = 0

    private var currentOffset: CGFloat {
        let proposed = settledOffset + dragTranslation
        return min(0, max(-revealWidth, proposed))
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(actionColor.opacity(0.92))

                Button(role: actionRole, action: onAction) {
                    VStack(spacing: 4) {
                        Image(systemName: actionSystemImage)
                            .font(.system(size: 14, weight: .semibold))
                        Text(actionTitle)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundColor(.white)
                    .frame(width: revealWidth)
                    .frame(maxHeight: .infinity)
                }
                .buttonStyle(.plain)
            }
            .frame(width: revealWidth)
            .offset(x: max(0, revealWidth + currentOffset))

            content()
                .offset(x: currentOffset)
                .allowsHitTesting(abs(currentOffset) < 1 && abs(dragTranslation) < 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .highPriorityGesture(dragGesture)
        .simultaneousGesture(
            TapGesture().onEnded {
                guard settledOffset < 0 else { return }
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                    settledOffset = 0
                }
            }
        )
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($dragTranslation) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    state = 0
                    return
                }
                state = value.translation.width
            }
            .onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else {
                    return
                }
                let projected = settledOffset + value.predictedEndTranslation.width
                withAnimation(.spring(response: 0.24, dampingFraction: 0.9)) {
                    if projected < -(revealWidth * 0.55) {
                        settledOffset = -revealWidth
                    } else {
                        settledOffset = 0
                    }
                }
            }
    }
}

private struct CLINewSessionSheet: View {
    let agent: CloudAgent
    let client: RelayClient
    let flavor: String
    let onSessionCreated: (CLISession) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var machines: [RelayClient.RemoteMachine] = []
    @State private var selectedMachineId: String = ""
    @State private var workingDirectory: String = ""
    @State private var isLoadingMachines = false
    @State private var isSpawning = false
    @State private var errorMessage: String?
    @State private var pendingDirectoryApproval: String?
    @State private var recentDirectories: [String] = []

    private let maxRecentDirectoryCount = 5

    var body: some View {
        NavigationStack {
            Form {
                Section("机器") {
                    if isLoadingMachines {
                        HStack {
                            ProgressView()
                            Text("正在加载机器...")
                                .foregroundColor(.secondary)
                        }
                    } else if machines.isEmpty {
                        Text("暂无可用机器，请先完成终端配对")
                            .foregroundColor(.secondary)
                    } else {
                        Picker("目标机器", selection: $selectedMachineId) {
                            ForEach(machines) { machine in
                                Text(machine.displayName).tag(machine.id)
                            }
                        }

                        if let machine = machines.first(where: { $0.id == selectedMachineId }) {
                            Text("\(machine.host) · \(machine.homeDir)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Section("守护进程") {
                    if let machine = selectedMachine {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(daemonStatusColor(for: machine))
                                .frame(width: 8, height: 8)

                            Text(daemonStatusText(for: machine))
                                .font(.subheadline)

                            Spacer()

                            if let daemonPid = machine.daemonPid {
                                Text("PID \(daemonPid)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Text("最后活跃 \(relativeTime(machine.activeAt))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    } else {
                        Text("请选择目标机器")
                            .foregroundColor(.secondary)
                    }
                }

                Section("工作目录") {
                    TextField("例如 ~/project", text: $workingDirectory)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)

                    if !recentDirectories.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(recentDirectories, id: \.self) { directory in
                                    Button {
                                        workingDirectory = directory
                                    } label: {
                                        Text(directory)
                                            .font(.caption)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Color.secondary.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section {
                    Button {
                        Task {
                            await createSession(approvedNewDirectoryCreation: false)
                        }
                    } label: {
                        if isSpawning {
                            HStack {
                                ProgressView()
                                Text("正在创建...")
                            }
                        } else {
                            Text("创建会话")
                        }
                    }
                    .disabled(!canCreateSession)
                }
            }
            .navigationTitle("新建会话")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
            }
            .task {
                await loadMachines()
            }
            .alert("创建失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { newValue in
                    if !newValue { errorMessage = nil }
                }
            )) {
                Button("确定", role: .cancel) {
                    errorMessage = nil
                }
            } message: {
                Text(errorMessage ?? "未知错误")
            }
            .alert("需要创建目录", isPresented: Binding(
                get: { pendingDirectoryApproval != nil },
                set: { newValue in
                    if !newValue { pendingDirectoryApproval = nil }
                }
            )) {
                Button("取消", role: .cancel) {
                    pendingDirectoryApproval = nil
                }
                Button("继续") {
                    Task {
                        await createSession(approvedNewDirectoryCreation: true)
                    }
                }
            } message: {
                Text("目录不存在：\(pendingDirectoryApproval ?? "")，是否允许远端创建？")
            }
        }
    }

    private var selectedMachine: RelayClient.RemoteMachine? {
        machines.first(where: { $0.id == selectedMachineId })
    }

    private var canCreateSession: Bool {
        !selectedMachineId.isEmpty && !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isSpawning
    }

    private func loadMachines() async {
        isLoadingMachines = true
        defer { isLoadingMachines = false }

        do {
            let fetched = try await client.fetchMachines()
            machines = fetched
            if selectedMachineId.isEmpty {
                selectedMachineId = fetched.first?.id ?? ""
            }
            loadRecentDirectories()
            if let preferred = recentDirectories.first {
                workingDirectory = preferred
            } else if workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let machine = fetched.first(where: { $0.id == selectedMachineId }) {
                workingDirectory = machine.homeDir
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func createSession(approvedNewDirectoryCreation: Bool) async {
        let directory = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return }

        isSpawning = true
        defer { isSpawning = false }

        do {
            let spawnResult = try await client.spawnSession(
                machineId: selectedMachineId,
                directory: directory,
                flavor: flavor,
                approvedNewDirectoryCreation: approvedNewDirectoryCreation
            )

            switch spawnResult {
            case .success(let sessionId):
                let sessions = try await client.fetchSessions()
                if let created = sessions.first(where: { $0.id == sessionId }) {
                    cacheRecentDirectory(directory)
                    onSessionCreated(created)
                    dismiss()
                    return
                }

                let fallback = CLISession(
                    id: sessionId,
                    seq: 0,
                    createdAt: Date(),
                    updatedAt: Date(),
                    active: true,
                    activeAt: Date(),
                    metadata: CLISession.Metadata(
                        path: directory,
                        host: "Unknown",
                        machineId: selectedMachineId,
                        hostPid: nil,
                        flavor: flavor,
                        homeDir: directory,
                        version: "unknown",
                        platform: nil,
                        claudeSessionId: nil,
                        codexSessionId: nil,
                        opencodeSessionId: nil,
                        geminiSessionId: nil,
                        customTitle: nil,
                        summary: nil,
                        gitStatus: nil
                    ),
                    agentState: nil,
                    agentStateVersion: 0
                )
                cacheRecentDirectory(directory)
                onSessionCreated(fallback)
                dismiss()

            case .requestDirectoryApproval(let directory):
                pendingDirectoryApproval = directory

            case .error(let message):
                errorMessage = message
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private var recentDirectoryStorageKey: String {
        "cli.newsession.recentDirs.\(agent.id)"
    }

    private func loadRecentDirectories() {
        let stored = UserDefaults.standard.stringArray(forKey: recentDirectoryStorageKey) ?? []
        recentDirectories = Array(stored.prefix(maxRecentDirectoryCount))
    }

    private func cacheRecentDirectory(_ directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var updated = UserDefaults.standard.stringArray(forKey: recentDirectoryStorageKey) ?? []
        updated.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        updated.insert(trimmed, at: 0)
        if updated.count > maxRecentDirectoryCount {
            updated = Array(updated.prefix(maxRecentDirectoryCount))
        }

        UserDefaults.standard.set(updated, forKey: recentDirectoryStorageKey)
        recentDirectories = updated
    }

    private func daemonStatusText(for machine: RelayClient.RemoteMachine) -> String {
        let raw = machine.daemonStatus?.lowercased() ?? ""
        if raw.contains("running") || raw.contains("active") || raw.contains("online") {
            return "守护进程运行中"
        }
        if raw.contains("stopped") || raw.contains("offline") || raw.contains("dead") {
            return "守护进程未运行"
        }
        if let status = machine.daemonStatus, !status.isEmpty {
            return "守护进程状态: \(status)"
        }
        if machine.daemonPid != nil {
            return "守护进程已连接"
        }
        return "守护进程状态未知"
    }

    private func daemonStatusColor(for machine: RelayClient.RemoteMachine) -> Color {
        let raw = machine.daemonStatus?.lowercased() ?? ""
        if raw.contains("running") || raw.contains("active") || raw.contains("online") {
            return .green
        }
        if raw.contains("stopped") || raw.contains("offline") || raw.contains("dead") {
            return .gray
        }
        return machine.daemonPid != nil ? .blue : .gray
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Session List Item

struct SessionListItem: View {
    let session: CLISession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(session.displayName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(timeString)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 8) {
                statusChip
                providerChip
            }

            Text(session.displayPath)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if let gitStatus = session.metadata?.gitStatus {
                gitRow(gitStatus)
            }
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private func gitRow(_ gitStatus: CLISession.Metadata.GitStatus) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(gitStatus.branch ?? "unknown")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            if let changedFiles = gitStatus.changedFiles {
                Text("\(changedFiles) files")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let added = gitStatus.addedLines {
                Text("+\(added)")
                    .font(.caption2)
                    .foregroundColor(.green)
            }

            if let deleted = gitStatus.deletedLines {
                Text("-\(deleted)")
                    .font(.caption2)
                    .foregroundColor(.red)
            }

            if let ahead = gitStatus.aheadCount, ahead > 0 {
                Text("↑\(ahead)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if let behind = gitStatus.behindCount, behind > 0 {
                Text("↓\(behind)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
    }

    private var statusChip: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.caption2)
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.12))
        .clipShape(Capsule())
    }

    private var providerChip: some View {
        Text(providerLabel)
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.secondary.opacity(0.10))
            .clipShape(Capsule())
    }

    private var statusText: String {
        switch session.sessionStatus {
        case .thinking:
            return "思考中"
        case .permissionRequired:
            return "需权限"
        case .disconnected:
            return "离线"
        case .error:
            return "异常"
        case .waiting:
            return "在线"
        }
    }

    private var statusColor: Color {
        switch session.sessionStatus {
        case .thinking:
            return .blue
        case .permissionRequired:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        case .waiting:
            return .green
        }
    }

    private var providerLabel: String {
        switch session.metadata?.flavor?.lowercased() {
        case "codex": return "codex"
        case "opencode": return "opencode"
        case "gemini": return "gemini"
        default: return "claude"
        }
    }

    private var timeString: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: session.activeAt, relativeTo: Date())
    }
}

// MARK: - Status Dot

struct StatusDot: View {
    let state: State

    enum State {
        case online
        case offline
        case thinking
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .overlay(
                state == .thinking ? Circle().stroke(color, lineWidth: 2).scaleEffect(1.5).opacity(0.5) : nil
            )
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: state == .thinking)
    }

    private var color: Color {
        switch state {
        case .online:
            return .green
        case .offline:
            return .gray
        case .thinking:
            return .blue
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        SessionListView(agent: CloudAgent(
            id: "preview-id",
            name: "claude-code",
            displayName: "Claude Code",
            description: "远程控制本地 Claude Code",
            type: "claudecode",
            config: "{\"serverURL\":\"\(CoreServerDefaults.relayServerURL)\"}",
            permissions: "{}",
            status: "active",
            createdAt: Date(),
            updatedAt: Date()
        ))
    }
}
