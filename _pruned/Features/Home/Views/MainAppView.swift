import SwiftUI
import Combine
import UIKit

// MARK: - Helper Functions

/// Format path for display: show first and last segments completely, truncate middle if too long
/// 确保第一段和最后一段始终完整显示，中间用省略号
private func formatPathForDisplay(_ path: String, maxLength: Int = 40) -> String {
    // If path is short enough, return as-is
    if path.count <= maxLength {
        return path
    }

    // Split path by separator (/ or \)
    let separator: Character = path.contains("/") ? "/" : "\\"
    let components = path.split(separator: separator).map(String.init)

    // If only 1 component, keep it complete (don't truncate)
    guard components.count > 1 else {
        return path
    }

    // If only 2 components, show "first/.../last" or "first/last"
    if components.count == 2 {
        let first = components[0]
        let last = components[1]
        // If they fit together, show without ellipsis
        if first.count + last.count + 1 <= maxLength {
            return "\(first)\(separator)\(last)"
        }
        // Otherwise show with ellipsis (both segments still complete)
        return "\(first)\(separator)...\(separator)\(last)"
    }

    // 3+ components: always show "first/.../last" (keep both complete)
    let first = components.first!
    let last = components.last!

    return "\(first)\(separator)...\(separator)\(last)"
}

// MARK: - 2. Background Particle Engine

struct DashboardParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var opacity: Double
    var blur: CGFloat
}

class BackgroundEngine: ObservableObject {
    var particles: [DashboardParticle] = []

    func setup(size: CGSize) {
        guard particles.isEmpty else { return }
        for _ in 0..<40 {
            let p = DashboardParticle(
                position: CGPoint(
                    x: CGFloat.random(in: 0...size.width),
                    y: CGFloat.random(in: 0...size.height)
                ),
                velocity: CGVector(
                    dx: CGFloat.random(in: -0.15...0.15),
                    dy: CGFloat.random(in: -0.15...0.15)
                ),
                radius: CGFloat.random(in: 1...3),
                opacity: Double.random(in: 0.1...0.4),
                blur: CGFloat.random(in: 0...2)
            )
            particles.append(p)
        }
    }

    func update(date: Date, size: CGSize) {
        for i in particles.indices {
            var p = particles[i]
            p.position.x += p.velocity.dx
            p.position.y += p.velocity.dy
            if p.position.x < -10 { p.position.x = size.width + 10 }
            if p.position.x > size.width + 10 { p.position.x = -10 }
            if p.position.y < -10 { p.position.y = size.height + 10 }
            if p.position.y > size.height + 10 { p.position.y = -10 }
            particles[i] = p
        }
    }
}

class StatisticEngine: ObservableObject {
    @Published var todayCount: Int = 0
    @Published var totalCount: Int = 0
    @Published var archivedCount: Int = 0
    @Published var buildingCount: Int = 0

    func load(contextService: ContextService) {
        Task { @MainActor in
            do {
                let summary = try await contextService.fetchSummary()
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    self.todayCount = summary.todayCount
                    self.totalCount = summary.totalCount
                    self.archivedCount = summary.archivedCount
                    self.buildingCount = summary.buildingCount
                }
            } catch {
                print("❌ [StatisticEngine] Failed to load summary: \(error)")
            }
        }
    }
}

// MARK: - 3. Main App Entry

struct MainAppView: View {
    @Environment(\.colorScheme) var colorScheme
    @EnvironmentObject var homeViewModel: HomeViewModel

    @State private var sheetPosition: SheetPosition = .high
    @State private var showCreateContext: Bool = false
    @State private var showReviewContext: Bool = false
    @State private var showCreateAgent: Bool = false
    @State private var showServerConfig: Bool = false
    @State private var activeChatAgent: CloudAgent? = nil
    @State private var showSpaceDrawer: Bool = false
    @State private var spaceDrawerDetent: PresentationDetent = .fraction(0.4)
    @State private var selectedSpace: Space? = nil
    @State private var sessions: [SessionModel] = []
    @State private var activeSession: ContextGoSession? = nil  // 选中的 session
    @State private var showSessionPicker: Bool = false  // 显示 session 选择器

    @StateObject private var bgEngine = BackgroundEngine()
    @StateObject private var statEngine = StatisticEngine()
    @StateObject private var spaceViewModel = SpaceViewModel()
    @StateObject private var contextService = ContextService.shared
    private let sessionRepository = LocalSessionRepository.shared

    // ✅ NEW: Context review count
    @State private var draftContextCount: Int = 0

    // Combine cancellables for observing notifications
    @State private var cancellables = Set<AnyCancellable>()

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var agents: [CloudAgent] {
        homeViewModel.agents
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            // Layer 1: Background (KEEP BLACK - DO NOT CHANGE)
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()
                TimelineView(.animation) { timeline in
                    Canvas { context, size in
                        bgEngine.update(date: timeline.date, size: size)
                        for p in bgEngine.particles {
                            let rect = CGRect(x: p.position.x - p.radius, y: p.position.y - p.radius, width: p.radius*2, height: p.radius*2)
                            var ctx = context
                            ctx.opacity = p.opacity
                            if p.blur > 0 { ctx.addFilter(.blur(radius: p.blur)) }
                            ctx.fill(Path(ellipseIn: rect), with: .color(.white))
                        }
                    }
                }
                .onAppear { bgEngine.setup(size: CGSize(width: 400, height: 800)) }

                // 顶部数字展示 - 今日新增 Context 数
                VStack(spacing: 4) {
                    Spacer().frame(height: 20)
                    Text("\(statEngine.todayCount)")
                        .contentTransition(.numericText(value: Double(statEngine.todayCount)))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .shadow(color: .white.opacity(0.3), radius: 10, x: 0, y: 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: statEngine.todayCount)
                    Text("今日新增")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.6))
                }

                if sheetPosition == .low {
                    HStack {
                        Spacer()
                        Button(action: { showServerConfig = true }) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 18, weight: .light))
                                .foregroundColor(.white.opacity(0.4))
                                .padding(16)
                        }
                    }
                    .padding(.top, 0)
                    .transition(.opacity)
                }
            }
            .gesture(TapGesture().onEnded {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                    sheetPosition = .low
                }
            })

            // Layer 2: Sheet (ADAPTIVE)
            BottomSheet(position: $sheetPosition, colorScheme: colorScheme) {
                DashboardContent(
                    agents: agents,
                    sessions: $sessions,
                    selectedSpace: selectedSpace,
                    draftContextCount: draftContextCount,
                    buildingCount: statEngine.buildingCount,
                    colorScheme: colorScheme,
                    sheetPosition: sheetPosition,
                    onBuildContext: { showCreateContext = true },
                    onReviewContext: { showReviewContext = true },
                    onSwitchSpace: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            spaceDrawerDetent = .fraction(0.4)  // Reset to default size
                            showSpaceDrawer = true
                        }
                    },
                    onCreateAgent: { showCreateAgent = true },
                    onSelectAgent: { agent in
                        withAnimation(.easeInOut(duration: 0.3)) {
                            activeChatAgent = agent
                        }
                    },
                    onDeleteAgent: { agent in
                        // Find the CloudAgent and delete
                        if let cloudAgent = homeViewModel.agents.first(where: { $0.id == agent.id }) {
                            Task {
                                await homeViewModel.removeAgent(cloudAgent)
                            }
                        }
                    },
                    onEditAgent: { agent, newName in
                        // Find the CloudAgent and update name
                        if let cloudAgent = homeViewModel.agents.first(where: { $0.id == agent.id }) {
                            Task {
                                await homeViewModel.updateAgentName(cloudAgent, newName: newName)
                            }
                        }
                    },
                    onSelectSession: { sessionId, agentId in
                        // Find the session and open it
                        print("[Navigation] Session tapped: \(sessionId.prefix(8))")
                        print("[Navigation] Current state - activeChatAgent: \(activeChatAgent?.id.prefix(8) ?? "nil"), activeSession: \(activeSession?.id.prefix(8) ?? "nil")")

                        Task {
                            if let session = try? await sessionRepository.getSession(id: sessionId) {
                                await MainActor.run {
                                    print("[Navigation] Opening session: \(session.id.prefix(8))")
                                    routeToSessionDetail(session)
                                }
                            }
                        }
                    }
                )
            }

        }
        .ignoresSafeArea(edges: .bottom)
        .sheet(isPresented: $showServerConfig) {
            ServerConfigSheet()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $showCreateContext) { BuildContextView() }
        .sheet(isPresented: $showReviewContext) { ReviewContextView() }
        .sheet(isPresented: $showCreateAgent) {
            CreateAgentView()
                .environmentObject(homeViewModel)
        }
        .sheet(isPresented: $showSpaceDrawer) {
            SpaceDrawerView(
                selectedSpace: $selectedSpace,
                colorScheme: colorScheme,
                currentDetent: $spaceDrawerDetent
            )
            .environmentObject(spaceViewModel)
            .presentationDetents([.fraction(0.4), .large], selection: $spaceDrawerDetent)
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: Binding(
            get: {
                if let agent = activeChatAgent,
                   let cloudAgent = homeViewModel.agents.first(where: { $0.id == agent.id }),
                   !cloudAgent.channelType.isOpenClaw {
                    return true
                }
                return false
            },
            set: { newValue in
                if !newValue {
                    activeChatAgent = nil
                }
            }
        )) {
            if let agent = activeChatAgent,
               let cloudAgent = homeViewModel.agents.first(where: { $0.id == agent.id }),
               !cloudAgent.channelType.isOpenClaw {
                NavigationStack {
                    SessionListView(
                        agent: cloudAgent,
                        onSelectSession: { session in
                            openCLISession(session, for: cloudAgent)
                        }
                    )
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        // OpenClaw Session List - sheet presentation
        .sheet(isPresented: Binding(
            get: {
                if let agent = activeChatAgent,
                   let cloudAgent = homeViewModel.agents.first(where: { $0.id == agent.id }),
                   cloudAgent.channelType.isOpenClaw {
                    return true
                }
                return false
            },
            set: { newValue in
                if !newValue {
                    activeChatAgent = nil
                }
            }
        )) {
            if let agent = activeChatAgent,
               let cloudAgent = homeViewModel.agents.first(where: { $0.id == agent.id }),
               cloudAgent.channelType.isOpenClaw {
                OpenClawSessionListView(
                    agent: cloudAgent,
                    onDismiss: {
                        activeChatAgent = nil
                    },
                    onSelectSession: { selected in
                        openOpenClawSession(selected)
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
        // Session view - conditional based on session's channel type
        .fullScreenCover(item: $activeSession) { session in
            if let cloudAgent = homeViewModel.agents.first(where: { $0.id == session.agentId }) {
                if !cloudAgent.channelType.isOpenClaw || session.isCLISession {
                    CLINativeSessionContainerView(
                        contextSession: session,
                        cloudAgent: cloudAgent,
                        onDismiss: { activeSession = nil }
                    )
                } else {
                    // OpenClaw session - open ChatView with sessionId
                    NavigationView {
                        ChatView(
                            agent: cloudAgent,
                            sessionId: session.id,
                            sessionKey: session.channelMetadataDict?["sessionKey"] as? String,
                            sessionTitle: session.title,
                            onDismiss: {
                                activeSession = nil
                            }
                        )
                    }
                }
            }
        }
        .onAppear {
            // 加载 Agents
            Task {
                await homeViewModel.loadAgents()
            }

            loadSessions()
            connectAndSyncAllAgents()
            setupNotificationObservers()

            // Load spaces from API
            Task {
                await spaceViewModel.loadSpaces()
                // Set default space if not already set
                if selectedSpace == nil {
                    selectedSpace = spaceViewModel.defaultSpace
                }
            }

            // ✅ Load draft context count for Review button
            Task {
                await loadDraftContextCount()
            }

            // ✅ Load stats summary for homepage numbers
            statEngine.load(contextService: contextService)
        }
    }

    private func openCLISession(_ cliSession: CLISession, for cloudAgent: CloudAgent) {
        Task {
            let contextSession: ContextGoSession
            do {
                let allSessions = try await sessionRepository.getAllSessions(agentId: cloudAgent.id)
                if let matched = allSessions.first(where: { $0.cliSessionId == cliSession.id }) {
                    contextSession = matched
                } else {
                    contextSession = ContextGoSession.fromCLI(
                        cliSessionId: cliSession.id,
                        agent: cloudAgent,
                        title: cliSession.displayName,
                        preview: "",
                        lastMessageTime: cliSession.activeAt,
                        isActive: cliSession.active,
                        metadata: nil
                    )
                }
            } catch {
                print("❌ [MainAppView] Failed to resolve CLI session before opening: \(error)")
                contextSession = ContextGoSession.fromCLI(
                    cliSessionId: cliSession.id,
                    agent: cloudAgent,
                    title: cliSession.displayName,
                    preview: "",
                    lastMessageTime: cliSession.activeAt,
                    isActive: cliSession.active,
                    metadata: nil
                )
            }

            await MainActor.run {
                routeToSessionDetail(contextSession)
            }
        }
    }

    private func openOpenClawSession(_ session: ContextGoSession) {
        routeToSessionDetail(session)
    }

    @MainActor
    private func routeToSessionDetail(_ session: ContextGoSession, dismissDelay: TimeInterval = 0.25) {
        let needsDismissal = activeChatAgent != nil
        if needsDismissal {
            activeChatAgent = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    activeSession = session
                }
            }
        } else {
            withAnimation(.easeInOut(duration: 0.3)) {
                activeSession = session
            }
        }
    }

    // MARK: - Helper Methods

    /// Setup notification observers
    private func setupNotificationObservers() {
        // Listen for CLI sessions sync completion
        NotificationCenter.default.publisher(for: NSNotification.Name("CLISessionsSynced"))
            .sink { notification in
                if let userInfo = notification.userInfo,
                   let count = userInfo["count"] as? Int {
                    print("🔔 Received CLISessionsSynced notification - \(count) sessions")
                    Task { @MainActor in
                        await self.loadSessionsAsync()
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name("CLISessionDeleted"))
            .sink { notification in
                let deletedSessionId = notification.userInfo?["sessionId"] as? String
                Task { @MainActor in
                    if let deletedSessionId,
                       let active = self.activeSession,
                       active.id == deletedSessionId || active.cliSessionId == deletedSessionId {
                        self.activeSession = nil
                    }
                    await self.loadSessionsAsync()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name("CLISessionUpdated"))
            .sink { notification in
                let hasMetadataUpdate = notification.userInfo?["hasMetadataUpdate"] as? Bool ?? false
                guard hasMetadataUpdate else { return }

                Task { @MainActor in
                    let displayName = (notification.userInfo?["displayName"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let sessionId = (notification.userInfo?["sessionId"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if let sessionId, !sessionId.isEmpty,
                       let displayName, !displayName.isEmpty,
                       self.applySessionTitleUpdate(sessionId: sessionId, title: displayName) {
                        return
                    }

                    await self.loadSessionsAsync()
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name("ContextGoSessionUpdated"))
            .sink { notification in
                Task { @MainActor in
                    let title = (notification.userInfo?["title"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let sessionId = (notification.userInfo?["sessionId"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    if let sessionId, !sessionId.isEmpty,
                       let title, !title.isEmpty,
                       self.applySessionTitleUpdate(sessionId: sessionId, title: title) {
                        return
                    }

                    await self.loadSessionsAsync()
                }
            }
            .store(in: &cancellables)

        // ✅ Listen for Agent deletion
        NotificationCenter.default.publisher(for: NSNotification.Name("AgentDeleted"))
            .sink { notification in
                print("🔔 Received AgentDeleted notification - reloading sessions")
                Task { @MainActor in
                    await self.loadSessionsAsync()
                }
            }
            .store(in: &cancellables)

        // ✅ Listen for context archive/unarchive events
        NotificationCenter.default.publisher(for: NSNotification.Name("ContextUpdated"))
            .sink { _ in
                print("🔔 Received ContextUpdated notification")
                Task { @MainActor in
                    await self.loadDraftContextCount()
                    self.statEngine.load(contextService: self.contextService)
                }
            }
            .store(in: &cancellables)
    }

    /// Connect all non-OpenClaw agents and sync sessions
    private func connectAndSyncAllAgents() {
        Task {
            // Get all session-list based agents (Claude Code, Codex, Gemini CLI, OpenCode)
            let cliAgents = homeViewModel.agents.filter { !$0.channelType.isOpenClaw }

            guard !cliAgents.isEmpty else {
                print("ℹ️ No CLI relay agents to connect")
                return
            }

            print("🔄 Auto-connecting \(cliAgents.count) CLI relay agent(s)...")

            for agent in cliAgents {
                ConnectionManager.shared.connectRelay(agent: agent)

                if let client = ConnectionManager.shared.getRelayClient(for: agent) {
                    do {
                        _ = try await client.syncSessionsToLocal(agentId: agent.id, repository: sessionRepository)
                    } catch {
                        print("⚠️ [MainAppView] Initial CLI sync failed for agent \(agent.displayName): \(error)")
                    }
                }
            }
        }
    }

    /// Load sessions from database
    private func loadSessions() {
        Task {
            await loadSessionsAsync()
        }
    }

    /// Async version of loadSessions
    private func loadSessionsAsync() async {
        do {
            let contextGoSessions = try await sessionRepository.getAllSessions(agentId: nil)
            let activeSessionsOnly = contextGoSessions.filter(\.isActive)
            let normalizedSessions = await collapseOpenClawDuplicateSessions(activeSessionsOnly)

            // Convert ContextGoSession to SessionModel
            var newSessions: [SessionModel] = []
            for session in normalizedSessions {
                var resolvedSession = session
                guard let cloudAgent = await resolveAgentForSession(session: &resolvedSession, availableAgents: homeViewModel.agents) else {
                    print("⚠️ Session \(session.id.prefix(20)) has no matching agent (agentId: \(session.agentId))")
                    continue
                }
                let agent = cloudAgent
                var sessionAgentType = cloudAgent.channelType

                // Parse channelMetadata JSON (for CLI sessions)
                var sessionMetadata: SessionMetadata? = nil
                var displayTitle = session.title  // Default to database title

                if let metadataDict = session.channelMetadataDict {
                    let summaryTitle = extractSummaryTitle(from: metadataDict)

                    sessionMetadata = SessionMetadata(
                        path: metadataDict["path"] as? String,
                        pathBasename: metadataDict["pathBasename"] as? String,
                        machineId: metadataDict["machineId"] as? String,
                        host: metadataDict["host"] as? String,
                        hostPid: metadataDict["hostPid"] as? Int,
                        customTitle: metadataDict["customTitle"] as? String,
                        aiProvider: metadataDict["flavor"] as? String,
                        homeDir: metadataDict["homeDir"] as? String,
                        claudeSessionId: metadataDict["claudeSessionId"] as? String,
                        codexSessionId: metadataDict["codexSessionId"] as? String,
                        opencodeSessionId: metadataDict["opencodeSessionId"] as? String,
                        geminiSessionId: metadataDict["geminiSessionId"] as? String,
                        rawJSON: session.channelMetadata
                    )

                    // Override display channel type based on runtime flavor (for CLI sessions)
                    if let flavor = metadataDict["flavor"] as? String {
                        switch flavor.lowercased() {
                        case "codex":
                            sessionAgentType = .codex
                        case "opencode":
                            sessionAgentType = .openCode
                        case "gemini":
                            sessionAgentType = .geminiCLI
                        case "claude":
                            sessionAgentType = .claudeCode
                        default:
                            break
                        }
                    }

                    if let customTitle = metadataDict["customTitle"] as? String, !customTitle.isEmpty {
                        displayTitle = customTitle
                    } else if let summaryTitle, !summaryTitle.isEmpty {
                        displayTitle = summaryTitle
                    } else if let pathBasename = metadataDict["pathBasename"] as? String, !pathBasename.isEmpty {
                        displayTitle = pathBasename
                    }
                }

                // Format time string
                let timeString = formatTimeString(session.lastMessageTime)

                let sessionModel = SessionModel(
                    id: session.id,
                    agentId: resolvedSession.agentId,
                    title: displayTitle,  // Use prioritized title
                    timeString: timeString,
                    date: resolvedSession.lastMessageTime,
                    preview: resolvedSession.preview,
                    agent: agent,
                    agentChannelType: sessionAgentType,
                    sessionMetadata: sessionMetadata
                )
                newSessions.append(sessionModel)
            }

            // Update on main thread
            await MainActor.run {
                sessions = newSessions
            }
        } catch {
            print("❌ Failed to load sessions: \(error)")
        }
    }

    private func collapseOpenClawDuplicateSessions(_ sessions: [ContextGoSession]) async -> [ContextGoSession] {
        var grouped: [String: [ContextGoSession]] = [:]
        var passthrough: [ContextGoSession] = []

        for session in sessions {
            guard session.tags.contains("openclaw"),
                  let logicalKey = openClawLogicalKey(for: session) else {
                passthrough.append(session)
                continue
            }
            grouped["\(session.agentId)|\(logicalKey)", default: []].append(session)
        }

        var removedIds = Set<String>()
        for (groupKey, values) in grouped where values.count > 1 {
            let sorted = values.sorted { lhs, rhs in
                let lhsScore = openClawSessionQualityScore(lhs)
                let rhsScore = openClawSessionQualityScore(rhs)
                if lhsScore != rhsScore {
                    return lhsScore > rhsScore
                }
                if lhs.lastMessageTime != rhs.lastMessageTime {
                    return lhs.lastMessageTime > rhs.lastMessageTime
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt > rhs.updatedAt
                }
                return lhs.id > rhs.id
            }

            guard let keeper = sorted.first else { continue }
            for duplicate in sorted.dropFirst() {
                removedIds.insert(duplicate.id)

                var archived = duplicate
                archived.markRemoteDeleted(provider: "openclaw")
                do {
                    try await sessionRepository.updateSession(archived, notifyCloud: false)
                    print("[MainAppView] 🧹 Archived duplicate OpenClaw session \(duplicate.id) in group \(groupKey), keep=\(keeper.id)")
                } catch {
                    print("[MainAppView] ⚠️ Failed to archive duplicate OpenClaw session \(duplicate.id): \(error)")
                }
            }
        }

        let dedupedOpenClaw = grouped.values.compactMap { group -> ContextGoSession? in
            let candidates = group.filter { !removedIds.contains($0.id) }
            guard !candidates.isEmpty else { return nil }
            return candidates.max { lhs, rhs in
                if openClawSessionQualityScore(lhs) != openClawSessionQualityScore(rhs) {
                    return openClawSessionQualityScore(lhs) < openClawSessionQualityScore(rhs)
                }
                if lhs.lastMessageTime != rhs.lastMessageTime {
                    return lhs.lastMessageTime < rhs.lastMessageTime
                }
                if lhs.updatedAt != rhs.updatedAt {
                    return lhs.updatedAt < rhs.updatedAt
                }
                return lhs.id < rhs.id
            }
        }

        return (passthrough + dedupedOpenClaw)
            .sorted { $0.lastMessageTime > $1.lastMessageTime }
    }

    private func openClawLogicalKey(for session: ContextGoSession) -> String? {
        guard let metadata = session.channelMetadataDict else { return nil }
        if let key = metadata["sessionKey"] as? String, !key.isEmpty {
            return "key:\(key)"
        }
        if let remoteSessionId = metadata["remoteSessionId"] as? String, !remoteSessionId.isEmpty {
            return "remote:\(remoteSessionId)"
        }
        return nil
    }

    private func openClawSessionQualityScore(_ session: ContextGoSession) -> Int {
        switch session.syncStatus {
        case .synced:
            return 4
        case .pending:
            return 3
        case .conflict:
            return 2
        case .localOnly:
            return 1
        }
    }

    private func resolveAgentForSession(session: inout ContextGoSession, availableAgents: [CloudAgent]) async -> CloudAgent? {
        if let existing = availableAgents.first(where: { $0.id == session.agentId }) {
            return existing
        }

        guard let metadata = session.channelMetadataDict,
              metadata["cliSessionId"] != nil ||
              metadata["contextgoSessionId"] != nil ||
              metadata["contextGoSessionId"] != nil ||
              metadata["claudeSessionId"] != nil ||
              metadata["codexSessionId"] != nil ||
              metadata["geminiSessionId"] != nil ||
              metadata["opencodeSessionId"] != nil,
              let flavor = (metadata["flavor"] as? String)?.lowercased() else {
            return nil
        }

        let machineId = metadata["machineId"] as? String
        let candidateAgents = availableAgents.filter { !$0.channelType.isOpenClaw }
        let reboundAgent = candidateAgents.first { agent in
            guard agentMatchesFlavor(agent, flavor: flavor) else { return false }
            if let machineId, !machineId.isEmpty,
               let config = try? agent.cliRelayConfig(),
               let agentMachineId = config.machineId,
               !agentMachineId.isEmpty {
                return agentMachineId == machineId
            }
            return true
        }

        guard let reboundAgent else {
            return nil
        }

        if session.agentId != reboundAgent.id {
            print("[MainAppView] 🔁 Rebinding orphan session \(session.id.prefix(20)) from \(session.agentId) -> \(reboundAgent.id) (flavor=\(flavor))")
            session.agentId = reboundAgent.id
            session.updatedAt = Date()
            do {
                try await sessionRepository.updateSession(session)
            } catch {
                print("[MainAppView] ⚠️ Failed to persist rebound session \(session.id.prefix(20)): \(error)")
            }
        }

        return reboundAgent
    }

    private func agentMatchesFlavor(_ agent: CloudAgent, flavor: String) -> Bool {
        switch flavor {
        case "claude":
            return agent.avatar == nil || agent.avatar == "ClaudeCodeLogo" || agent.avatar == "terminal.fill"
        case "codex":
            return agent.avatar == "CodexLogo"
        case "opencode":
            return agent.avatar == "OpenCodeLogo"
        case "gemini":
            return agent.avatar == "GeminiCliLogo"
        default:
            return false
        }
    }

    private func extractSummaryTitle(from metadataDict: [String: Any]) -> String? {
        if let summary = metadataDict["summary"] as? [String: Any],
           let text = summary["text"] as? String,
           !text.isEmpty {
            return text
        }

        if let rawJSON = metadataDict["rawJSON"] as? String,
           let data = rawJSON.data(using: .utf8),
           let rawObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let summary = rawObject["summary"] as? [String: Any],
           let text = summary["text"] as? String,
           !text.isEmpty {
            return text
        }

        return nil
    }

    private func formatTimeString(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        let components = calendar.dateComponents([.minute, .hour, .day], from: date, to: now)

        if let day = components.day, day > 0 {
            if day == 1 {
                return "昨天"
            } else if day < 7 {
                let formatter = DateFormatter()
                formatter.dateFormat = "EEEE"
                formatter.locale = Locale(identifier: "zh_CN")
                return formatter.string(from: date)
            } else {
                let formatter = DateFormatter()
                formatter.dateFormat = "MM-dd"
                return formatter.string(from: date)
            }
        } else if let hour = components.hour, hour > 0 {
            return "\(hour) 小时前"
        } else if let minute = components.minute, minute > 0 {
            return "\(minute) 分钟前"
        } else {
            return "刚刚"
        }
    }

    @MainActor
    private func applySessionTitleUpdate(sessionId: String, title: String) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return false }

        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else {
            return false
        }

        let original = sessions[index]
        if original.title == trimmedTitle {
            return true
        }

        var metadata = original.sessionMetadata
        if metadata != nil {
            metadata?.customTitle = trimmedTitle
        }

        sessions[index] = SessionModel(
            id: original.id,
            agentId: original.agentId,
            title: trimmedTitle,
            timeString: original.timeString,
            date: original.date,
            preview: original.preview,
            agent: original.agent,
            agentChannelType: original.agentChannelType,
            sessionMetadata: metadata
        )
        return true
    }

    /// Load draft context count for Review button
    private func loadDraftContextCount() async {
        do {
            let draftContexts = try await contextService.listContexts(status: "draft")
            await MainActor.run {
                draftContextCount = draftContexts.count
                print("✅ [MainAppView] Loaded \(draftContextCount) draft contexts")
            }
        } catch {
            print("❌ [MainAppView] Failed to load draft contexts: \(error)")
        }
    }
}

private struct CLINativeSessionContainerView: View {
    let contextSession: ContextGoSession
    let cloudAgent: CloudAgent
    let onDismiss: () -> Void

    @State private var cliSession: CLISession?
    @State private var cliClient: RelayClient?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let cliSession, let cliClient {
                NavigationStack {
                    SessionDetailView(
                        session: cliSession,
                        client: cliClient,
                        onDismiss: onDismiss
                    )
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                    Text("正在加载原生会话…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)

                    if let loadError {
                        Text(loadError)
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemBackground))
            }
        }
        .task(id: contextSession.id) {
            await bootstrap()
        }
    }

        @MainActor
    private func bootstrap() async {
        guard let client = ConnectionManager.shared.getRelayClient(for: cloudAgent) else {
            loadError = "CLI 客户端未初始化"
            return
        }

        ConnectionManager.shared.connectRelay(agent: cloudAgent)

        let remoteSessionId = contextSession.cliSessionId ?? contextSession.id
        if !remoteSessionId.isEmpty {
            do {
                if let remote = try await client.fetchSession(sessionId: remoteSessionId) {
                    cliSession = remote
                    cliClient = client
                    loadError = nil
                    return
                }
            } catch {
                print("⚠️ [CLINativeSessionContainer] Failed to fetch remote session \(remoteSessionId): \(error)")
            }
        }

        guard let mappedSession = mapContextSessionToCLI(contextSession) else {
            loadError = "会话元数据不完整"
            return
        }

        cliSession = mappedSession
        cliClient = client
    }

    private func mapContextSessionToCLI(_ contextSession: ContextGoSession) -> CLISession? {
        let sessionId = contextSession.cliSessionId ?? contextSession.id
        guard !sessionId.isEmpty else { return nil }

        let metadataDict = contextSession.channelMetadataDict ?? [:]
        let rawMetadata = parseJSONObject(metadataDict["rawJSON"] as? String)

        let path = ((rawMetadata?["path"] as? String) ?? (metadataDict["path"] as? String) ?? "/")
        let host = ((rawMetadata?["host"] as? String) ?? (metadataDict["host"] as? String) ?? "Unknown")
        let machineId = ((rawMetadata?["machineId"] as? String) ?? (metadataDict["machineId"] as? String) ?? "")
        let hostPid = parseInt(rawMetadata?["hostPid"] ?? metadataDict["hostPid"])
        let flavor = ((rawMetadata?["flavor"] as? String) ?? (metadataDict["flavor"] as? String))
        let homeDir = ((rawMetadata?["homeDir"] as? String) ?? (metadataDict["homeDir"] as? String) ?? NSHomeDirectory())
        let version = ((rawMetadata?["version"] as? String) ?? "unknown")
        let platform = rawMetadata?["platform"] as? String
        let claudeSessionId = (rawMetadata?["claudeSessionId"] as? String) ?? (metadataDict["claudeSessionId"] as? String)
        let codexSessionId = (rawMetadata?["codexSessionId"] as? String) ?? (metadataDict["codexSessionId"] as? String)
        let opencodeSessionId = (rawMetadata?["opencodeSessionId"] as? String) ?? (metadataDict["opencodeSessionId"] as? String)
        let geminiSessionId = (rawMetadata?["geminiSessionId"] as? String) ?? (metadataDict["geminiSessionId"] as? String)
        let customTitle = (rawMetadata?["customTitle"] as? String)
            ?? (rawMetadata?["name"] as? String)
            ?? (metadataDict["customTitle"] as? String)
            ?? contextSession.title

        var summary: CLISession.Metadata.Summary? = nil
        if let summaryRaw = rawMetadata?["summary"] as? [String: Any],
           let text = summaryRaw["text"] as? String,
           !text.isEmpty {
            summary = CLISession.Metadata.Summary(
                text: text,
                updatedAt: parseDate(summaryRaw["updatedAt"]) ?? contextSession.updatedAt
            )
        } else if let metadataSummary = metadataDict["summary"] as? [String: Any],
                  let text = metadataSummary["text"] as? String,
                  !text.isEmpty {
            summary = CLISession.Metadata.Summary(
                text: text,
                updatedAt: parseDate(metadataSummary["updatedAt"]) ?? contextSession.updatedAt
            )
        }

        var gitStatus: CLISession.Metadata.GitStatus? = nil
        if let gitRaw = rawMetadata?["gitStatus"] as? [String: Any] {
            gitStatus = CLISession.Metadata.GitStatus(
                branch: gitRaw["branch"] as? String,
                isDirty: gitRaw["isDirty"] as? Bool,
                changedFiles: parseInt(
                    gitRaw["changedFiles"]
                    ?? gitRaw["filesChanged"]
                    ?? gitRaw["files"]
                ),
                addedLines: parseInt(
                    gitRaw["addedLines"]
                    ?? gitRaw["added"]
                    ?? gitRaw["insertions"]
                    ?? gitRaw["additions"]
                ),
                deletedLines: parseInt(
                    gitRaw["deletedLines"]
                    ?? gitRaw["deleted"]
                    ?? gitRaw["deletions"]
                    ?? gitRaw["removals"]
                ),
                upstreamBranch: (gitRaw["upstreamBranch"] as? String) ?? (gitRaw["upstream"] as? String),
                aheadCount: parseInt(gitRaw["aheadCount"] ?? gitRaw["ahead"]),
                behindCount: parseInt(gitRaw["behindCount"] ?? gitRaw["behind"])
            )
        }

        let runtimeRaw = (rawMetadata?["runtime"] as? [String: Any]) ?? (metadataDict["runtime"] as? [String: Any])
        var runtime: CLISession.Metadata.Runtime? = nil
        if let runtimeRaw {
            runtime = CLISession.Metadata.Runtime(
                provider: runtimeRaw["provider"] as? String,
                agentVersion: runtimeRaw["agentVersion"] as? String,
                status: runtimeRaw["status"] as? String,
                statusDetail: runtimeRaw["statusDetail"] as? String,
                permissionMode: runtimeRaw["permissionMode"] as? String,
                permissionModeLabel: runtimeRaw["permissionModeLabel"] as? String,
                reasoningEffort: runtimeRaw["reasoningEffort"] as? String,
                reasoningEffortLabel: runtimeRaw["reasoningEffortLabel"] as? String,
                supportedReasoningEfforts: runtimeRaw["supportedReasoningEfforts"] as? [String],
                opencodeModeId: runtimeRaw["opencodeModeId"] as? String,
                opencodeModeLabel: runtimeRaw["opencodeModeLabel"] as? String,
                opencodeModelId: runtimeRaw["opencodeModelId"] as? String,
                opencodeVariant: runtimeRaw["opencodeVariant"] as? String,
                opencodeAvailableVariants: runtimeRaw["opencodeAvailableVariants"] as? [String],
                model: runtimeRaw["model"] as? String,
                contextSize: parseInt(runtimeRaw["contextSize"]),
                contextWindow: parseInt(runtimeRaw["contextWindow"]),
                contextRemainingPercent: parseDouble(runtimeRaw["contextRemainingPercent"]),
                mcpReady: runtimeRaw["mcpReady"] as? [String],
                mcpFailed: runtimeRaw["mcpFailed"] as? [String],
                mcpCancelled: runtimeRaw["mcpCancelled"] as? [String],
                mcpToolNames: runtimeRaw["mcpToolNames"] as? [String],
                mcpStartupPhase: runtimeRaw["mcpStartupPhase"] as? String,
                mcpStartupUpdatedAt: parseDate(runtimeRaw["mcpStartupUpdatedAt"]),
                skillAvailableCount: parseInt(runtimeRaw["skillAvailableCount"]),
                skillLoadedCount: parseInt(runtimeRaw["skillLoadedCount"]),
                skillLoadedUris: parseStringList(runtimeRaw["skillLoadedUris"] ?? runtimeRaw["loadedSkillUris"]),
                skillLoadState: runtimeRaw["skillLoadState"] as? String,
                skillLastSyncAt: parseDate(runtimeRaw["skillLastSyncAt"]),
                skillLastError: runtimeRaw["skillLastError"] as? String,
                skills: parseRuntimeSkills(runtimeRaw["skills"]),
                updatedAt: parseDate(runtimeRaw["updatedAt"]),
                titleStatus: runtimeRaw["titleStatus"] as? String,
                titleSource: runtimeRaw["titleSource"] as? String,
                titleUpdatedAt: parseDate(runtimeRaw["titleUpdatedAt"]),
                titleLastError: runtimeRaw["titleLastError"] as? String
            )
        }

        let metadata = CLISession.Metadata(
            path: path.isEmpty ? "/" : path,
            host: host,
            machineId: machineId,
            hostPid: hostPid,
            flavor: flavor,
            homeDir: homeDir,
            version: version,
            platform: platform,
            runtime: runtime,
            claudeSessionId: claudeSessionId,
            codexSessionId: codexSessionId,
            opencodeSessionId: opencodeSessionId,
            geminiSessionId: geminiSessionId,
            customTitle: customTitle,
            summary: summary,
            gitStatus: gitStatus
        )

        return CLISession(
            id: sessionId,
            seq: parseInt(metadataDict["seq"]) ?? 0,
            createdAt: contextSession.createdAt,
            updatedAt: contextSession.updatedAt,
            active: contextSession.isActive,
            activeAt: contextSession.lastMessageTime,
            metadata: metadata,
            agentState: nil,
            agentStateVersion: parseInt(metadataDict["agentStateVersion"]) ?? 0
        )
    }

    private func parseJSONObject(_ json: String?) -> [String: Any]? {
        guard let json,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func parseInt(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let numberValue = value as? NSNumber { return numberValue.intValue }
        if let stringValue = value as? String { return Int(stringValue) }
        return nil
    }

    private func parseDouble(_ value: Any?) -> Double? {
        if let doubleValue = value as? Double { return doubleValue }
        if let numberValue = value as? NSNumber { return numberValue.doubleValue }
        if let stringValue = value as? String { return Double(stringValue) }
        return nil
    }

    private func parseStringList(_ value: Any?) -> [String] {
        guard let items = value as? [Any] else { return [] }
        return items.compactMap { item in
            guard let text = item as? String else { return nil }
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return normalized.isEmpty ? nil : normalized
        }
    }

    private func parseBool(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "1", "yes", "y"].contains(normalized) { return true }
            if ["false", "0", "no", "n"].contains(normalized) { return false }
        }
        return nil
    }

    private func parseRuntimeSkill(_ value: Any?) -> CLISession.Metadata.Runtime.Skill? {
        guard let dict = value as? [String: Any] else { return nil }
        let skillUri = ((dict["skillUri"] as? String) ?? (dict["uri"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let skillUri, !skillUri.isEmpty else { return nil }

        let name = (dict["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let description = (dict["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = (dict["scope"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = (dict["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let spaceId = ((dict["spaceId"] as? String) ?? (dict["spaceID"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CLISession.Metadata.Runtime.Skill(
            skillUri: skillUri,
            name: (name?.isEmpty == false) ? name : nil,
            description: (description?.isEmpty == false) ? description : nil,
            scope: (scope?.isEmpty == false) ? scope : nil,
            type: (type?.isEmpty == false) ? type : nil,
            spaceId: (spaceId?.isEmpty == false) ? spaceId : nil,
            isSystem: parseBool(dict["isSystem"]),
            isLoaded: dict["isLoaded"] as? Bool,
            lastLoadedAt: parseDate(dict["lastLoadedAt"])
        )
    }

    private func parseRuntimeSkills(_ value: Any?) -> [CLISession.Metadata.Runtime.Skill]? {
        guard let items = value as? [Any] else { return nil }
        let parsed = items.compactMap(parseRuntimeSkill)
        return parsed.isEmpty ? nil : parsed
    }

    private func parseDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let interval = value as? TimeInterval {
            return interval > 1_000_000_000_000
                ? Date(timeIntervalSince1970: interval / 1000.0)
                : Date(timeIntervalSince1970: interval)
        }
        if let intValue = value as? Int {
            let interval = TimeInterval(intValue)
            return interval > 1_000_000_000_000
                ? Date(timeIntervalSince1970: interval / 1000.0)
                : Date(timeIntervalSince1970: interval)
        }
        if let string = value as? String {
            let iso = ISO8601DateFormatter()
            if let date = iso.date(from: string) { return date }
            if let interval = TimeInterval(string) {
                return interval > 1_000_000_000_000
                    ? Date(timeIntervalSince1970: interval / 1000.0)
                    : Date(timeIntervalSince1970: interval)
            }
        }
        return nil
    }
}

// MARK: - 4. Components

enum SheetPosition {
    case low, high
    func height(screenHeight: CGFloat) -> CGFloat {
        switch self {
        case .low: return screenHeight * 0.25
        case .high: return screenHeight * 0.85
        }
    }
}

struct BottomSheet<Content: View>: View {
    @Binding var position: SheetPosition
    let colorScheme: ColorScheme
    let content: () -> Content

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var body: some View {
        GeometryReader { geo in
            let height = position.height(screenHeight: geo.size.height)
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 36, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: colorScheme == .dark
                                ? [
                                    Color(red: 0.16, green: 0.18, blue: 0.23).opacity(0.96),
                                    Color(red: 0.09, green: 0.1, blue: 0.14).opacity(0.94)
                                ]
                                : [
                                    Color.white.opacity(0.96),
                                    Color.white.opacity(0.92)
                                ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(
                        color: colorScheme == .dark ? Color.black.opacity(0.7) : Color.black.opacity(0.08),
                        radius: colorScheme == .dark ? 34 : 20,
                        x: 0,
                        y: 12
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 36, style: .continuous)
                            .stroke(
                                colorScheme == .dark
                                    ? Color.white.opacity(0.28)
                                    : Color.black.opacity(0.1),
                                lineWidth: 1
                            )
                    )

                VStack(spacing: 0) {
                    // 顶部手柄 - 只有这里可以拖动调整 Sheet 位置
                    Capsule()
                        .fill(theme.primaryText.opacity(colorScheme == .dark ? 0.32 : 0.2))
                        .frame(width: 40, height: 4)
                        .padding(.top, 12)
                        .padding(.bottom, 20)
                        .contentShape(Rectangle().size(width: geo.size.width, height: 40)) // 扩大拖动区域
                        .gesture(
                            DragGesture()
                                .onEnded { val in
                                    let snap = geo.size.height * 0.15
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                        if val.translation.height > snap {
                                            // Drag down
                                            position = .low
                                        } else if val.translation.height < -snap {
                                            // Drag up
                                            position = .high
                                        }
                                    }
                                }
                        )

                    content()
                }
                .contentShape(Rectangle())
                .simultaneousGesture(
                    TapGesture().onEnded {
                        guard position == .low else { return }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                            position = .high
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 36, style: .continuous))
            }
            .frame(height: height, alignment: .bottom)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)  // 防止键盘顶起 Sheet
        }
    }
}

// MARK: - 5. Dashboard Content (Updated)

enum TimeFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case lastDay = "Last 24h"
    case lastWeek = "Last 7 Days"
    case lastMonth = "Last 30 Days"

    var id: String { rawValue }
}

struct DashboardContent: View {
    let agents: [CloudAgent]
    @Binding var sessions: [SessionModel]
    let selectedSpace: Space?
    let draftContextCount: Int  // ✅ NEW: Draft context count
    let buildingCount: Int      // ✅ Building context count
    let colorScheme: ColorScheme
    let sheetPosition: SheetPosition

    var onBuildContext: () -> Void
    var onReviewContext: () -> Void
    var onSwitchSpace: () -> Void
    var onCreateAgent: () -> Void
    var onSelectAgent: (CloudAgent) -> Void
    var onDeleteAgent: (CloudAgent) -> Void
    var onEditAgent: (CloudAgent, String) -> Void  // NEW: Edit agent name
    var onSelectSession: (String, String) -> Void  // (sessionId, agentId)

    // Filter States
    @State private var searchText = ""
    @State private var isSearchActive = false // To control search expansion
    @State private var timeFilter: TimeFilter = .all
    @FocusState private var isSearchFocused: Bool

    // Agent Expansion State
    @State private var showAllAgents = false

    // Keyboard height tracking
    @State private var keyboardHeight: CGFloat = 0

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    // ✅ Computed subtitle for Review button
    private var reviewSubtitle: String {
        draftContextCount > 0 ? "\(draftContextCount) pending" : "No pending"
    }

    // ✅ Computed subtitle for Build button
    private var buildSubtitle: String {
        buildingCount > 0 ? "\(buildingCount) building" : "Create context"
    }

    private var displayedAgents: [CloudAgent] {
        showAllAgents ? agents : Array(agents.prefix(4))
    }

    // ✅ Build & Review action row as separate ViewBuilder to help compiler type-check
    @ViewBuilder
    private var contextActionRow: some View {
        HStack(spacing: 16) {
            ContextActionButton(
                title: "Build",
                subtitle: buildSubtitle,
                icon: "hammer.fill",
                color: .blue,
                colorScheme: colorScheme,
                action: onBuildContext
            )
            ContextActionButton(
                title: "Review",
                subtitle: reviewSubtitle,
                icon: "doc.text.magnifyingglass",
                color: .orange,
                colorScheme: colorScheme,
                action: onReviewContext
            )
        }
    }

    // ✅ Context section as separate ViewBuilder to help compiler type-check
    @ViewBuilder
    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Context")
                    .font(.title3).bold()
                    .foregroundColor(theme.primaryText.opacity(0.9))

                Spacer()

                SpaceSwitchButton(
                    selectedSpace: selectedSpace,
                    theme: theme,
                    action: onSwitchSpace
                )
            }
            .padding(.horizontal, 24)

            contextActionRow
                .padding(.horizontal, 24)
        }
    }

    // ✅ Agents section as separate ViewBuilder to help compiler type-check
    @ViewBuilder
    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Agents", actionIcon: "plus", colorScheme: colorScheme, action: onCreateAgent)

            if agents.isEmpty {
                VStack(spacing: 0) {
                    Button(action: onCreateAgent) {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(theme.accentBlue.opacity(0.1))
                                    .frame(width: 64, height: 64)
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 32, weight: .light))
                                    .foregroundColor(theme.accentBlue)
                            }
                            VStack(spacing: 4) {
                                Text("添加 Agent")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                Text("创建你的第一个 AI 助手")
                                    .font(.system(size: 13))
                                    .foregroundColor(theme.secondaryText)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(theme.cardBackground))
                        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.border, lineWidth: 0.5, antialiased: true))
                    }
                    .buttonStyle(EmptyStateButtonStyle())
                }
                .padding(.horizontal, 24)
            } else {
                let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(displayedAgents) { agent in
                        AgentCard(
                            agent: agent,
                            isOnline: ConnectionManager.shared.getConnectionState(agentId: agent.id) == .connected,
                            theme: theme,
                            action: { onSelectAgent(agent) },
                            onDelete: { onDeleteAgent(agent) },
                            onEdit: { newName in onEditAgent(agent, newName) }
                        )
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .scale(scale: 0.96)),
                            removal: .agentDestroy
                        ))
                    }
                }
                .padding(.horizontal, 24)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: displayedAgents.map(\.id))

                if agents.count > 4 {
                    Button(action: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            showAllAgents.toggle()
                        }
                    }) {
                        HStack(spacing: 6) {
                            Text(showAllAgents ? "Show Less" : "More (\(agents.count - 4))")
                                .font(.subheadline).fontWeight(.medium)
                            Image(systemName: showAllAgents ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                        .foregroundColor(theme.accentBlue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(theme.cardBackground)
                        .cornerRadius(12)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.accentBlue.opacity(0.3), lineWidth: 1))
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    var filteredSessions: [SessionModel] {
        sessions.filter { session in
            // 1. Search
            let matchSearch = searchText.isEmpty ||
                              session.title.localizedCaseInsensitiveContains(searchText) ||
                              session.preview.localizedCaseInsensitiveContains(searchText)

            // 2. Time
            let matchTime: Bool
            let calendar = Calendar.current
            let now = Date()

            switch timeFilter {
            case .all:
                matchTime = true
            case .lastDay:
                let oneDayAgo = calendar.date(byAdding: .day, value: -1, to: now)!
                matchTime = session.date >= oneDayAgo
            case .lastWeek:
                let sevenDaysAgo = calendar.date(byAdding: .day, value: -7, to: now)!
                matchTime = session.date >= sevenDaysAgo
            case .lastMonth:
                let thirtyDaysAgo = calendar.date(byAdding: .day, value: -30, to: now)!
                matchTime = session.date >= thirtyDaysAgo
            }

            return matchSearch && matchTime
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 32) {
                // Wrap non-pinned sections in a regular VStack
                VStack(spacing: 32) {
                    // --- Section 1: Contexts (Build/Review) ---
                    contextSection

                // --- Section 2: Agents ---
                agentsSection
                } // Close VStack for non-pinned sections

                // --- Section 3: Sessions ---
                VStack(spacing: 0) {
                    // Sessions Header - 与搜索框在同一行，动画切换
                    HStack(spacing: 0) {
                        if !isSearchActive {
                            // Default state: Title + Search icon
                            HStack {
                                Text("Sessions")
                                    .font(.title3)
                                    .fontWeight(.bold)
                                    .foregroundColor(theme.primaryText)

                                Spacer()

                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        isSearchActive = true
                                    }
                                }) {
                                    Image(systemName: "magnifyingglass")
                                        .font(.system(size: 18))
                                        .foregroundColor(theme.primaryText)
                                        .padding(8)
                                }
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                        } else {
                            // Active state: Search bar
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 14))
                                    .foregroundColor(theme.secondaryText)

                                TextField("搜索 Session...", text: $searchText)
                                    .font(.subheadline)
                                    .foregroundColor(theme.primaryText)
                                    .focused($isSearchFocused)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.never)

                                if !searchText.isEmpty {
                                    Button(action: {
                                        searchText = ""
                                    }) {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 14))
                                            .foregroundColor(theme.secondaryText)
                                    }
                                }

                                Button(action: {
                                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                        isSearchActive = false
                                        searchText = ""
                                        isSearchFocused = false
                                    }
                                }) {
                                    Text("取消")
                                        .font(.subheadline)
                                        .foregroundColor(theme.accentBlue)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(theme.cardBackground)
                            .cornerRadius(12)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                            .onAppear {
                                isSearchFocused = true
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)

                    // Time Filters
                    VStack(spacing: 12) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(TimeFilter.allCases) { filter in
                                    Button(action: {
                                        withAnimation { timeFilter = filter }
                                    }) {
                                        Text(filter.rawValue)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .background(timeFilter == filter ? theme.accentBlue.opacity(0.3) : theme.cardBackground)
                                            .foregroundColor(timeFilter == filter ? theme.accentBlue : theme.primaryText)
                                            .cornerRadius(20)
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 20)
                                                    .stroke(timeFilter == filter ? theme.accentBlue.opacity(0.5) : theme.border, lineWidth: 1)
                                            )
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 8)

                    // Session List
                    LazyVStack(spacing: 12) {
                        ForEach(filteredSessions) { session in
                            Button(action: {
                                onSelectSession(session.id, session.agentId)
                            }) {
                                HStack(alignment: .center, spacing: 12) {
                                    // Left: Content (Title + Meta Info)
                                    VStack(alignment: .leading, spacing: 8) {
                                        // Row 1: Title
                                        Text(session.title)
                                            .font(.body)
                                            .fontWeight(.medium)
                                            .foregroundColor(theme.primaryText)
                                            .lineLimit(1)
                                            .multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)

                                        // Row 2: Meta Info (Agent Type + Path)
                                        HStack(alignment: .center, spacing: 6) {
                                            // Channel logo instead of agent avatar
                                            Image(session.agentChannelType.logoName)
                                                .resizable()
                                                .scaledToFit()
                                                .frame(width: 16, height: 16)
                                                .clipShape(Circle())

                                            Text(session.agent.uiDisplayName)
                                                .font(.caption)
                                                .foregroundColor(theme.secondaryText)

                                            // Path (for Claude Code sessions) - 显示在 agent name 后面，同一行
                                            if let metadata = session.sessionMetadata,
                                               let path = metadata.path {
                                                Circle()
                                                    .fill(theme.primaryText.opacity(0.3))
                                                    .frame(width: 2, height: 2)

                                                Text(path)
                                                    .font(.caption2)
                                                    .foregroundColor(theme.tertiaryText)
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                            }
                                        }
                                    }

                                    Spacer()  // 推动时间到最右边

                                    // Right: Time - 垂直居中
                                    Text(session.timeString)
                                        .font(.caption)
                                        .foregroundColor(theme.tertiaryText)
                                }
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(theme.cardBackground)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .strokeBorder(
                                            theme.border,
                                            lineWidth: 0.5,
                                            antialiased: true
                                        )
                                )
                            }
                            .buttonStyle(ScaleButtonStyle())
                        }

                        if filteredSessions.isEmpty {
                            Text("No sessions found").foregroundColor(theme.tertiaryText).padding(40)
                        }
                    }
                    .padding(.horizontal, 24)
                } // Close VStack for Sessions section

                Spacer().frame(height: 50)
            }
            .padding(.top, 10)
            .padding(.bottom, keyboardHeight > 0 ? keyboardHeight - 100 : 0)  // 为键盘留出空间
        }
        .simultaneousGesture(
            // 点击 ScrollView 任意位置关闭键盘
            TapGesture().onEnded {
                if isSearchActive {
                    isSearchFocused = false
                }
            }
        )
        .onTapGesture {
            // Fallback: 点击空白区域关闭键盘
            if isSearchActive {
                isSearchFocused = false
            }
        }
        .onAppear {
            // 监听键盘事件
            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillShowNotification,
                object: nil,
                queue: .main
            ) { notification in
                if let keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect {
                    withAnimation(.easeOut(duration: 0.25)) {
                        keyboardHeight = keyboardFrame.height
                    }
                }
            }

            NotificationCenter.default.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    keyboardHeight = 0
                }
            }
        }
    }
}

// MARK: - New Subcomponents

struct ContextActionButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let color: Color
    let colorScheme: ColorScheme
    let action: () -> Void

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(color.opacity(0.2))
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.title3)
                        .foregroundColor(color)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundColor(theme.secondaryText)
                }
                Spacer()
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        theme.border,
                        lineWidth: 0.5,
                        antialiased: true
                    )
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

// MARK: - Create Space Sheet

struct CreateSpaceSheet: View {
    let colorScheme: ColorScheme
    @Environment(\.dismiss) var dismiss
    @EnvironmentObject var spaceViewModel: SpaceViewModel

    @State private var spaceName = ""
    @State private var displayName = ""
    @State private var isCreating = false
    @State private var showSuccess = false
    @State private var errorMessage: String?

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    // Validate space name (英文、数字、下划线、中划线)
    private var isValidSpaceName: Bool {
        let pattern = "^[a-zA-Z0-9_-]+$"
        return spaceName.range(of: pattern, options: .regularExpression) != nil
    }

    private var canCreate: Bool {
        !spaceName.isEmpty && isValidSpaceName && !isCreating
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button("取消") {
                        dismiss()
                    }
                    .foregroundColor(theme.primaryText)
                    .opacity(showSuccess ? 0 : 1)

                    Spacer()

                    Text(showSuccess ? "创建成功" : "创建 Space")
                        .font(.headline)
                        .foregroundColor(showSuccess ? .green : theme.primaryText)

                    Spacer()

                    Button(action: createSpace) {
                        if isCreating {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: theme.accentBlue))
                                .scaleEffect(0.8)
                        } else {
                            Text("创建")
                                .fontWeight(.semibold)
                                .foregroundColor(canCreate ? theme.accentBlue : theme.tertiaryText)
                        }
                    }
                    .disabled(!canCreate)
                    .opacity(showSuccess ? 0 : 1)
                }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(theme.primaryBackground)

            Divider()

            ScrollView {
                VStack(spacing: 24) {
                    // Icon
                    ZStack {
                        Circle()
                            .fill(theme.accentBlue.opacity(0.1))
                            .frame(width: 64, height: 64)
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 28))
                            .foregroundColor(theme.accentBlue)
                    }
                    .padding(.top, 20)

                    // Form
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Space 名称")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .foregroundColor(theme.primaryText)
                                Text("*")
                                    .foregroundColor(.red)
                            }

                            TextField("例如: my_project", text: $spaceName)
                                .font(.body)
                                .foregroundColor(theme.primaryText)
                                .padding(12)
                                .background(theme.cardBackground)
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(!spaceName.isEmpty && !isValidSpaceName ? Color.red : theme.border, lineWidth: 1)
                                )
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)

                            if !spaceName.isEmpty && !isValidSpaceName {
                                Text("只能包含英文、数字、下划线和中划线")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            } else {
                                Text("用于系统识别的唯一标识（显示名称可使用中文）")
                                    .font(.caption)
                                    .foregroundColor(theme.secondaryText)
                            }
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("显示名称（可选）")
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundColor(theme.primaryText)

                            TextField("例如: 我的项目", text: $displayName)
                                .font(.body)
                                .foregroundColor(theme.primaryText)
                                .padding(12)
                                .background(theme.cardBackground)
                                .cornerRadius(10)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 10)
                                        .stroke(theme.border, lineWidth: 1)
                                )

                            Text("用于在界面上展示，为空时使用 Space 名称")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                        }
                    }
                    .padding(.horizontal, 20)

                    // Error message
                    if let error = errorMessage {
                        HStack {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundColor(.red)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 30)
            }
            .background(theme.primaryBackground)
        }
        .opacity(showSuccess ? 0.3 : 1)

        // Success overlay
        if showSuccess {
            VStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.1))
                        .frame(width: 80, height: 80)

                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.green)
                }

                Text("Space 创建成功")
                    .font(.headline)
                    .foregroundColor(theme.primaryText)
            }
            .transition(.scale.combined(with: .opacity))
        }
        }
    }

    private func createSpace() {
        guard canCreate else { return }

        isCreating = true
        errorMessage = nil

        Task {
            let success = await spaceViewModel.createSpace(
                displayName: displayName.isEmpty ? spaceName : displayName,
                name: spaceName.isEmpty ? nil : spaceName
            )

            await MainActor.run {
                isCreating = false
                if success {
                    // Show success feedback
                    showSuccess = true

                    // Haptic feedback
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)

                    // Dismiss after brief delay to show success state
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        dismiss()
                    }
                } else {
                    errorMessage = spaceViewModel.error ?? "创建失败"
                }
            }
        }
    }
}

struct SpaceDrawerView: View {
    @Binding var selectedSpace: Space?
    let colorScheme: ColorScheme
    @Binding var currentDetent: PresentationDetent
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""
    @State private var showCreateSpace = false
    @State private var spaceToDelete: Space?
    @State private var showDeleteConfirmation = false
    @EnvironmentObject var spaceViewModel: SpaceViewModel

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var filteredSpaces: [Space] {
        if searchText.isEmpty { return spaceViewModel.spaces }
        return spaceViewModel.spaces.filter { space in
            return space.displayName.localizedCaseInsensitiveContains(searchText)
        }
    }

    // Show search bar only when sheet is fully expanded
    private var shouldShowSearchBar: Bool {
        currentDetent == .large
    }

    var body: some View {
        NavigationView {
            ZStack {
                theme.primaryBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Search Bar - only show when expanded
                    if shouldShowSearchBar {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                            TextField("Search...", text: $searchText)
                                .font(.subheadline)
                                .foregroundColor(theme.primaryText)
                                .accentColor(theme.primaryText)

                            if !searchText.isEmpty {
                                Button(action: { searchText = "" }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(theme.secondaryText)
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 10)
                        .background(theme.cardBackground)
                        .cornerRadius(12)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Loading indicator
                    if spaceViewModel.isLoading {
                        ProgressView()
                            .padding(.top, 40)
                    } else if let error = spaceViewModel.error {
                        // Error state
                        VStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle")
                                .font(.largeTitle)
                                .foregroundColor(.orange)
                            Text(error)
                                .font(.caption)
                                .foregroundColor(theme.secondaryText)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                            Button("Retry") {
                                Task {
                                    await spaceViewModel.loadSpaces()
                                }
                            }
                            .foregroundColor(.blue)
                        }
                        .padding(.top, 40)
                    } else {
                        // Space List
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(filteredSpaces) { space in
                                    NavigationLink {
                                        SpaceArchivedContextsView(
                                            space: space,
                                            colorScheme: colorScheme,
                                            onUseSpace: {
                                                selectedSpace = space
                                                dismiss()
                                            }
                                        )
                                    } label: {
                                        SpaceListRow(
                                            space: space,
                                            isSelected: selectedSpace?.id == space.id,
                                            colorScheme: colorScheme
                                        )
                                    }
                                    .buttonStyle(.plain)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            spaceToDelete = space
                                            showDeleteConfirmation = true
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 30)
                        }
                    }
                }
            }
            .navigationTitle("Select Context Space")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: {
                        showCreateSpace = true
                    }) {
                        Image(systemName: "plus")
                            .foregroundColor(theme.primaryText)
                    }
                }
            }
        }
        .sheet(isPresented: $showCreateSpace) {
            CreateSpaceSheet(colorScheme: colorScheme)
                .environmentObject(spaceViewModel)
                .presentationDetents([.height(400)])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: currentDetent) { _, newDetent in
            // Clear search when sheet is collapsed
            if newDetent != .large {
                searchText = ""
            }
        }
        .alert("删除 Space", isPresented: $showDeleteConfirmation, presenting: spaceToDelete) { space in
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task {
                    let success = await spaceViewModel.deleteSpace(spaceId: space.id)
                    if success && selectedSpace?.id == space.id {
                        // 如果删除的是当前选中的 Space，清空选择
                        selectedSpace = nil
                    }
                }
            }
        } message: { space in
            Text("确定要删除 Space \"\(space.displayName)\" 吗？\n\n此操作无法撤销，该 Space 下的所有 Agent 也将被删除。")
        }
        .onAppear {
            // Load spaces when drawer opens
            if spaceViewModel.spaces.isEmpty {
                Task {
                    await spaceViewModel.loadSpaces()
                }
            }
        }
    }
}

struct SpaceListRow: View {
    let space: Space
    let isSelected: Bool
    let colorScheme: ColorScheme

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundColor(isSelected ? theme.accentBlue : theme.primaryText.opacity(0.2))

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(space.displayName)
                        .font(.headline)
                        .foregroundColor(theme.primaryText)
                }
                Text("\(space.taskCount) tasks • \(space.contextCount) contexts")
                    .font(.caption)
                    .foregroundColor(theme.secondaryText)
                Text("查看该空间已归档 Context")
                    .font(.caption2)
                    .foregroundColor(theme.secondaryText)
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundColor(theme.secondaryText)
        }
        .padding(16)
        .background(theme.cardBackground)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? theme.accentBlue.opacity(0.5) : theme.border, lineWidth: 1)
        )
    }

    // Helper function to format character count
    private func formatCharacters(_ count: Int) -> String {
        if count >= 1000 {
            return String(format: "%.1fk", Double(count) / 1000.0)
        }
        return "\(count)"
    }
}

struct SpaceArchivedContextsView: View {
    let space: Space
    let colorScheme: ColorScheme
    let onUseSpace: () -> Void

    @State private var contexts: [ContextMetadata] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @StateObject private var contextService = ContextService.shared

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var body: some View {
        ZStack {
            theme.primaryBackground.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
            } else if contexts.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "archivebox")
                        .foregroundColor(theme.secondaryText)
                    Text("该空间暂无 Context")
                        .font(.subheadline)
                        .foregroundColor(theme.secondaryText)
                }
            } else {
                List(contexts) { context in
                    NavigationLink {
                        SpaceArchivedContextDetailView(context: context, colorScheme: colorScheme)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(context.title)
                                .font(.headline)
                                .foregroundColor(theme.primaryText)
                                .lineLimit(2)

                            if let description = context.description, !description.isEmpty {
                                Text(description)
                                    .font(.caption)
                                    .foregroundColor(theme.secondaryText)
                                    .lineLimit(2)
                            }

                            HStack(spacing: 8) {
                                Text("v\(context.version)")
                                    .font(.caption2)
                                    .foregroundColor(theme.secondaryText)
                                Text(context.updatedAt)
                                        .font(.caption2)
                                        .foregroundColor(theme.secondaryText)
                                        .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(theme.cardBackground)
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle(space.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Use") {
                    onUseSpace()
                }
            }
        }
        .task {
            await loadArchivedContexts()
        }
    }

    private func loadArchivedContexts() async {
        isLoading = true
        errorMessage = nil

        do {
            contexts = try await contextService.listContexts(spaceId: space.id)
        } catch {
            errorMessage = "加载失败: \(error.localizedDescription)"
        }

        isLoading = false
    }
}

struct SpaceArchivedContextDetailView: View {
    let context: ContextMetadata
    let colorScheme: ColorScheme

    @StateObject private var contextService = ContextService.shared
    @State private var content = ""
    @State private var isLoading = false
    @State private var errorMessage: String?

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var body: some View {
        ZStack {
            theme.primaryBackground.ignoresSafeArea()

            if isLoading {
                ProgressView()
            } else if let errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(theme.secondaryText)
                }
            } else if content.isEmpty {
                Text("暂无内容")
                    .font(.subheadline)
                    .foregroundColor(theme.secondaryText)
            } else {
                ScrollView {
                    MarkdownText(markdown: content, isUserMessage: false)
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(context.title)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadContent()
        }
    }

    private func loadContent() async {
        isLoading = true
        errorMessage = nil

        do {
            content = try await contextService.downloadContent(contextId: context.id)
        } catch {
            errorMessage = "加载内容失败: \(error.localizedDescription)"
        }

        isLoading = false
    }
}

// MARK: - Reusable Components

struct AgentCard: View {
    let agent: CloudAgent
    let isOnline: Bool
    let theme: ThemeColors
    let action: () -> Void
    let onDelete: () -> Void
    var onEdit: ((String) -> Void)? = nil  // NEW: Edit callback

    @State private var showActionMenu: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var showEditSheet: Bool = false
    @State private var editedName: String = ""
    @State private var scale: CGFloat = 1.0

    var body: some View {
        ZStack {
            Group {
                if showActionMenu {
                    HStack(spacing: 10) {
                        Button(action: {
                            editedName = agent.uiDisplayName
                            showActionMenu = false
                            showEditSheet = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "pencil")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color.blue)
                                Text("编辑")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color.blue.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .stroke(Color.blue.opacity(0.28), lineWidth: 1)
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            showActionMenu = false
                            showDeleteConfirm = true
                        }) {
                            HStack(spacing: 8) {
                                Image(systemName: "trash.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color.red)
                                Text("删除")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(Color.red.opacity(0.12))
                            .overlay(
                                Capsule()
                                    .stroke(Color.red.opacity(0.28), lineWidth: 1)
                            )
                            .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    HStack {
                        ZStack {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 36, height: 36)
                                .overlay(
                                    Circle()
                                        .stroke(theme.border.opacity(0.7), lineWidth: 1)
                                )

                            Image(agent.channelType.logoName)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 36, height: 36)
                                .clipShape(Circle())
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(agent.uiDisplayName)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(theme.primaryText)

                            HStack(spacing: 4) {
                                Circle().fill(isOnline ? Color.green : Color.gray).frame(width: 6, height: 6)
                                Text(isOnline ? "Online" : "Offline").font(.caption2).foregroundColor(theme.secondaryText)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .padding(12)
            .frame(minHeight: 64)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(theme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 0.5, antialiased: true)
            )
            .scaleEffect(scale)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scale)
            .contentShape(Rectangle())
            .onTapGesture {
                if showActionMenu {
                    withAnimation(.easeOut(duration: 0.2)) {
                        showActionMenu = false
                    }
                } else {
                    action()
                }
            }
            .onLongPressGesture(minimumDuration: 0.5) {
                withAnimation(.easeOut(duration: 0.2)) {
                    showActionMenu = true
                }
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
            }
        }
        .alert("删除 Agent", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                onDelete()
            }
        } message: {
            Text("确定要删除 \(agent.uiDisplayName) 吗？此操作无法撤销。")
        }
        .sheet(isPresented: $showEditSheet) {
            EditAgentNameSheet(
                agentName: $editedName,
                theme: theme,
                onSave: {
                    if let onEdit = onEdit, !editedName.isEmpty {
                        onEdit(editedName)
                    }
                }
            )
            .presentationDetents([.height(280)])
            .presentationDragIndicator(.visible)
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showActionMenu)
    }
}

private struct AgentCardDestroyModifier: ViewModifier {
    let opacity: Double
    let scale: CGFloat
    let yOffset: CGFloat
    let rotation: Double
    let blurRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(opacity)
            .scaleEffect(scale)
            .offset(y: yOffset)
            .rotationEffect(.degrees(rotation))
            .blur(radius: blurRadius)
    }
}

private extension AnyTransition {
    static var agentDestroy: AnyTransition {
        .modifier(
            active: AgentCardDestroyModifier(
                opacity: 0,
                scale: 0.78,
                yOffset: 22,
                rotation: -8,
                blurRadius: 5
            ),
            identity: AgentCardDestroyModifier(
                opacity: 1,
                scale: 1,
                yOffset: 0,
                rotation: 0,
                blurRadius: 0
            )
        )
    }
}

// MARK: - Edit Agent Name Sheet

struct EditAgentNameSheet: View {
    @Binding var agentName: String
    let theme: ThemeColors
    let onSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Text("编辑名称")
                        .font(.headline)
                        .foregroundColor(theme.primaryText)

                    TextField("Agent 名称", text: $agentName)
                        .textFieldStyle(.roundedBorder)
                        .focused($isInputFocused)
                        .font(.body)
                        .padding(.horizontal, 20)
                }
                .padding(.top, 30)

                HStack(spacing: 16) {
                    Button("取消") {
                        dismiss()
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color(.systemGray5))
                    .foregroundColor(theme.primaryText)
                    .cornerRadius(12)

                    Button("保存") {
                        onSave()
                        dismiss()
                    }
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                    .disabled(agentName.isEmpty)
                    .opacity(agentName.isEmpty ? 0.5 : 1.0)
                }
                .padding(.horizontal, 20)

                Spacer()
            }
            .background(theme.primaryBackground)
            .onAppear {
                isInputFocused = true
            }
        }
    }
}

struct FilterChip: View {
    let title: String
    let icon: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption)
            Text(title).font(.caption).fontWeight(.medium)
            Image(systemName: "chevron.down").font(.caption2)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(isActive ? Color.blue.opacity(0.3) : Color.white.opacity(0.1))
        .foregroundColor(isActive ? .blue : .white)
        .cornerRadius(20)
        .overlay(RoundedRectangle(cornerRadius: 20).stroke(isActive ? Color.blue.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
    }
}

// MARK: - Space Switch Button

struct SpaceSwitchButton: View {
    let selectedSpace: Space?
    let theme: ThemeColors
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill")
                    .font(.caption)
                    .foregroundColor(theme.accentBlue)

                Text(selectedSpace?.displayName ?? "选择空间")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.primaryText)

                Image(systemName: "chevron.down")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundColor(theme.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(theme.accentBlue.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(theme.accentBlue.opacity(0.3), lineWidth: 1.5)
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

struct SectionHeader: View {
    let title: String
    let actionIcon: String
    let colorScheme: ColorScheme
    let action: () -> Void

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var body: some View {
        HStack {
            Text(title).font(.title3).bold().foregroundColor(theme.primaryText.opacity(0.9))
            Spacer()
            Button(action: action) {
                Image(systemName: actionIcon).font(.body).foregroundColor(theme.primaryText.opacity(0.7))
                    .padding(8).background(theme.cardBackground).clipShape(Circle())
            }
        }.padding(.horizontal, 24)
    }
}

// MARK: - Button Styles

/// iOS style button for empty state
struct EmptyStateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct CreateSheet: View {
    let title: String
    let icon: String
    let colorScheme: ColorScheme

    var theme: ThemeColors { ThemeColors(colorScheme: colorScheme) }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: icon).font(.system(size: 50)).foregroundColor(theme.accentBlue).padding(.top, 40)
            Text(title).font(.largeTitle).bold().foregroundColor(theme.primaryText)
            Text("Create Form Placeholder").foregroundColor(theme.secondaryText)
            Spacer()
        }
        .background(theme.primaryBackground.ignoresSafeArea())
    }
}

#Preview {
    MainAppView()
}
