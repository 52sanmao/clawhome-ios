//
//  OpenClawSessionListView.swift
//  contextgo
//
//  IronClaw Agent 的 Session 列表页（支持多 Session）
//  ✨ iOS 高级设计风格
//

import SwiftUI

/// IronClaw 多 Session 列表页
/// - 显示某个 IronClaw Agent 的所有会话
/// - 提供 "New Chat" 按钮，以时间戳 sessionKey 创建新会话
struct OpenClawSessionListView: View {
    let agent: CloudAgent
    var onDismiss: (() -> Void)?
    var onSelectSession: ((ContextGoSession) -> Void)?

    @State private var sessions: [ContextGoSession] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    @Environment(\.colorScheme) private var colorScheme

    private let sessionRepository = LocalSessionRepository.shared
    private let connectionManager = ConnectionManager.shared
    private let initialAutoOpenWindow: TimeInterval = 24 * 60 * 60

    private var initialAutoOpenFlagKey: String {
        "openclaw.sessionlist.initialAutoOpen.\(agent.id)"
    }

    var body: some View {
        NavigationView {
            ZStack {
                // 背景
                (colorScheme == .dark ? Color.black : Color(.systemGroupedBackground))
                    .ignoresSafeArea()

                if isLoading && sessions.isEmpty {
                    loadingView
                } else if sessions.isEmpty {
                    emptyStateView
                } else {
                    sessionListView
                }
            }
            .navigationTitle("会话列表")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: { onDismiss?() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundStyle(.secondary)
                            .symbolRenderingMode(.hierarchical)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: createNewSession) {
                        Image(systemName: "plus")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(.blue)
                    }
                }
            }
            .task {
                await loadSessions()
            }
            .alert("错误", isPresented: .constant(errorMessage != nil)) {
                Button("确定") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - Subviews

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.blue)
            Text("加载中...")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.1), Color.purple.opacity(0.1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 120, height: 120)

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .purple],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }

            VStack(spacing: 8) {
                Text("还没有对话")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundColor(.primary)

                Text("开始一段新的对话吧")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Button(action: createNewSession) {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16, weight: .medium))
                    Text("新对话")
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(
                    LinearGradient(
                        colors: [.blue, .purple],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .cornerRadius(28)
                .shadow(color: Color.blue.opacity(0.3), radius: 12, x: 0, y: 6)
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding()
    }

    private var sessionListView: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(sessions) { session in
                    SessionCard(session: session, colorScheme: colorScheme)
                        .onTapGesture {
                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                            onSelectSession?(session)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                deleteSession(session)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .refreshable {
            await loadSessions()
        }
    }

    // MARK: - Actions

    private func loadSessions() async {
        isLoading = true
        defer { isLoading = false }

        // Step 1: 连接 IronClaw（如果未连接）
        let gatewayURL: String? = (try? agent.openClawConfig())?.wsURL
        let client = connectionManager.getClient(
            for: agent.id,
            gatewayURL: gatewayURL
        )

        // 等待连接（最多 5 秒）
        if !client.isConnected {
            print("[SessionList] 📡 Connecting to IronClaw...")
            client.connect()
            for _ in 0..<50 {
                if client.isConnected {
                    break
                }
                try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            }
        }

        guard client.isConnected else {
            await MainActor.run {
                errorMessage = "无法连接到 IronClaw"
            }
            return
        }

        do {
            // Step 2: 获取 IronClaw 会话列表
            print("[SessionList] 🔄 Fetching remote sessions from IronClaw...")
            let response = try await client.fetchSessionsList(limit: 200, activeMinutes: 525600) // ~1 year

            guard let remoteSessions = response.sessions else {
                throw NSError(domain: "SessionList", code: 1, userInfo: [NSLocalizedDescriptionKey: "No sessions in response"])
            }

            print("[SessionList] 📬 Received \(remoteSessions.count) remote sessions")

            // 只处理 operator 格式的远程会话，并按 sessionKey 去重
            let operatorSessions = dedupeOperatorSessions(remoteSessions)
            print("[SessionList] ✅ Filtered+deduped to \(operatorSessions.count) operator sessions")

            let allLocalSessions = try await sessionRepository.getAllSessions(agentId: agent.id)
            let openClawLocalSessions = allLocalSessions.filter { session in
                session.tags.contains("openclaw")
            }
            let operatorLocalSessions = openClawLocalSessions.filter { session in
                guard let sessionKey = session.channelMetadataDict?["sessionKey"] as? String else { return false }
                return sessionKey.hasPrefix("agent:main:operator:")
            }

            var localByKey: [String: ContextGoSession] = [:]
            for session in operatorLocalSessions {
                if let key = session.channelMetadataDict?["sessionKey"] as? String {
                    localByKey[key] = session
                }
            }

            var nextLocalSessions: [ContextGoSession] = []

            for remoteSession in operatorSessions {
                if let existingSession = localByKey[remoteSession.key] {
                    var updatedSession = existingSession
                    if let updatedAt = remoteSession.updatedAt {
                        updatedSession.lastMessageTime = Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000.0)
                    }
                    if let displayName = remoteSession.displayName {
                        updatedSession.title = displayName
                    }
                    if let remoteSessionId = remoteSession.sessionId, !remoteSessionId.isEmpty {
                        var metadata = updatedSession.channelMetadataDict ?? [:]
                        metadata["remoteSessionId"] = remoteSessionId
                        updatedSession.setChannelMetadata(metadata)
                    }
                    try await sessionRepository.updateSession(updatedSession)
                    nextLocalSessions.append(updatedSession)
                    print("[SessionList] 🔄 Updated existing session: \(remoteSession.key)")
                } else {
                    let newSession = createSessionFromRemote(remoteSession)
                    try await sessionRepository.createSession(newSession)
                    nextLocalSessions.append(newSession)
                    print("[SessionList] ✨ Created new session: \(remoteSession.key)")
                }
            }

            let remoteKeys = Set(operatorSessions.map { $0.key })
            for localSession in operatorLocalSessions {
                guard let localKey = localSession.channelMetadataDict?["sessionKey"] as? String else { continue }
                if !remoteKeys.contains(localKey) {
                    var archivedSession = localSession
                    archivedSession.markRemoteDeleted(provider: "openclaw")
                    try await sessionRepository.updateSession(archivedSession)
                    print("[SessionList] 🗂️ Marked remote-deleted session as archived: \(localKey)")
                }
            }

            let hasAnyRemoteSession = !remoteSessions.isEmpty
            let hasAnyLocalSession = !openClawLocalSessions.isEmpty

            if nextLocalSessions.isEmpty && shouldAutoOpenInitialSession(
                hasAnyRemoteSession: hasAnyRemoteSession,
                hasAnyLocalSession: hasAnyLocalSession
            ) {
                let newSession = ContextGoSession.fromOpenClawNew(agent: agent)
                try await sessionRepository.createSession(newSession)
                nextLocalSessions = [newSession]
                markInitialAutoOpenHandled()
                await MainActor.run {
                    onSelectSession?(newSession)
                }
                print("[SessionList] ✨ First-link empty state: created a new session and opened chat")
            } else if hasAnyRemoteSession || hasAnyLocalSession || !nextLocalSessions.isEmpty {
                markInitialAutoOpenHandled()
            }

            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    sessions = nextLocalSessions.sorted { $0.lastMessageTime > $1.lastMessageTime }
                }
                print("[SessionList] ✅ Sync complete: \(nextLocalSessions.count) local sessions")
            }
        } catch {
            print("[SessionList] ❌ Sync failed: \(error)")
            await MainActor.run {
                errorMessage = "会话同步失败: \(error.localizedDescription)"
            }
        }
    }

    private func shouldAutoOpenInitialSession(
        hasAnyRemoteSession: Bool,
        hasAnyLocalSession: Bool
    ) -> Bool {
        guard !hasAnyRemoteSession, !hasAnyLocalSession else { return false }

        let defaults = UserDefaults.standard
        if defaults.bool(forKey: initialAutoOpenFlagKey) {
            return false
        }

        let age = Date().timeIntervalSince(agent.createdAt)
        guard age >= 0, age <= initialAutoOpenWindow else {
            return false
        }

        return true
    }

    private func markInitialAutoOpenHandled() {
        UserDefaults.standard.set(true, forKey: initialAutoOpenFlagKey)
    }

    private func dedupeOperatorSessions(_ remoteSessions: [SessionsListResponse.RemoteSessionInfo]) -> [SessionsListResponse.RemoteSessionInfo] {
        var byKey: [String: SessionsListResponse.RemoteSessionInfo] = [:]

        for session in remoteSessions where session.key.hasPrefix("agent:main:operator:") {
            if let existing = byKey[session.key] {
                let lhs = session.updatedAt ?? 0
                let rhs = existing.updatedAt ?? 0
                if lhs >= rhs {
                    byKey[session.key] = session
                }
            } else {
                byKey[session.key] = session
            }
        }

        return byKey.values.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
    }

    /// 从远程 session 信息创建本地 ContextGoSession
    private func createSessionFromRemote(_ remote: SessionsListResponse.RemoteSessionInfo) -> ContextGoSession {
        // 从 sessionKey 提取 suffix 作为唯一标识
        let suffix = remote.key.replacingOccurrences(of: "agent:main:operator:", with: "")

        let sessionId: String
        if let remoteSessionId = remote.sessionId, !remoteSessionId.isEmpty {
            sessionId = remoteSessionId
        } else {
            sessionId = "session_\(suffix)"
        }

        // 生成时间戳（使用 updatedAt 或当前时间）
        let lastMessageTime: Date
        if let updatedAt = remote.updatedAt {
            lastMessageTime = Date(timeIntervalSince1970: TimeInterval(updatedAt) / 1000.0)
        } else {
            lastMessageTime = Date()
        }

        var metadata: [String: Any] = [
            "sessionKey": remote.key
        ]
        if let remoteSessionId = remote.sessionId, !remoteSessionId.isEmpty {
            metadata["remoteSessionId"] = remoteSessionId
        }

        var session = ContextGoSession(
            id: sessionId,
            agentId: agent.id,
            title: remote.displayName ?? "Chat",
            preview: "",
            tags: ["openclaw"],
            createdAt: lastMessageTime,
            updatedAt: lastMessageTime,
            lastMessageTime: lastMessageTime,
            isActive: false,
            isPinned: false,
            isArchived: false,
            channelMetadata: nil,
            messagesCachePath: SessionStorageLayout.messagesRelativePath(agentId: agent.id, sessionId: sessionId),
            syncStatus: .synced,
            lastSyncAt: Date()
        )

        session.setChannelMetadata(metadata)
        return session
    }

    private func createNewSession() {
        let newSession = ContextGoSession.fromOpenClawNew(agent: agent)

        Task {
            do {
                try await sessionRepository.createSession(newSession)
                markInitialAutoOpenHandled()
                await MainActor.run {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                        sessions.insert(newSession, at: 0)
                    }
                    onSelectSession?(newSession)
                }
            } catch {
                await MainActor.run {
                    errorMessage = "创建会话失败: \(error.localizedDescription)"
                }
            }
        }
    }

    private func deleteSession(_ session: ContextGoSession) {
        Task {
            try? await sessionRepository.deleteSession(id: session.id)
            await MainActor.run {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    sessions.removeAll { $0.id == session.id }
                }
            }
        }
    }

}

// MARK: - Session Card

private struct SessionCard: View {
    let session: ContextGoSession
    let colorScheme: ColorScheme

    @State private var isPressed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 标题和时间
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(colorScheme == .dark ? .white : .black)
                        .lineLimit(2)

                    if !session.preview.isEmpty {
                        Text(session.preview)
                            .font(.system(size: 14))
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                Text(timeString(session.lastMessageTime))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? Color(.systemGray6) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.05)
                        : Color.black.opacity(0.05),
                    lineWidth: 1
                )
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08),
            radius: 8,
            x: 0,
            y: 2
        )
        .scaleEffect(isPressed ? 0.97 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
    }

    private func timeString(_ date: Date) -> String {
        let calendar = Calendar.current
        let now = Date()

        if calendar.isDateInToday(date) {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: date)
        } else if calendar.isDateInYesterday(date) {
            return "昨天"
        } else if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            formatter.locale = Locale(identifier: "zh_CN")
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM/dd"
            return formatter.string(from: date)
        }
    }
}
