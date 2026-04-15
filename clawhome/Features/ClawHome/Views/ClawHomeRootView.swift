import SwiftUI
import UIKit

struct ClawHomeRootView: View {
    @StateObject private var store = LocalOpenClawGatewayStore.shared

    @State private var activeGatewayForSessions: LocalOpenClawGateway?
    @State private var activeChatEntry: ClawHomeChatEntry?

    @State private var showingAddGateway = false
    @State private var editingGateway: LocalOpenClawGateway?
    @State private var deletingGateway: LocalOpenClawGateway?
    @State private var recentSessions: [ContextGoSession] = []

    private let sessionRepository = LocalSessionRepository.shared

    var body: some View {
        NavigationStack {
            Group {
                if store.gateways.isEmpty {
                    emptyStateView
                } else {
                    List {
                        agentsSection
                        recentSessionsSection
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("爪家")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddGateway = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .task {
            await loadRecentSessions()
        }
        .onChange(of: store.gateways.map(\.id)) { _, _ in
            Task { await loadRecentSessions() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            Task { await loadRecentSessions() }
        }
        .sheet(isPresented: $showingAddGateway) {
            GatewayFormView(mode: .create) { name, wsURL in
                store.add(name: name, wsURL: wsURL)
                showingAddGateway = false
            }
        }
        .sheet(item: $editingGateway) { gateway in
            GatewayFormView(mode: .edit(gateway)) { name, wsURL in
                store.update(id: gateway.id, name: name, wsURL: wsURL)
                editingGateway = nil
            }
        }
        .sheet(item: $activeGatewayForSessions, onDismiss: {
            Task { await loadRecentSessions() }
        }) { gateway in
            OpenClawSessionListView(
                agent: gateway.cloudAgent,
                onDismiss: {
                    activeGatewayForSessions = nil
                },
                onSelectSession: { session in
                    let sessionKey = session.channelMetadataDict?["sessionKey"] as? String
                    activeChatEntry = ClawHomeChatEntry(
                        gateway: gateway,
                        sessionId: session.id,
                        sessionKey: sessionKey,
                        sessionTitle: session.title
                    )
                    activeGatewayForSessions = nil
                }
            )
        }
        .fullScreenCover(item: $activeChatEntry, onDismiss: {
            Task { await loadRecentSessions() }
        }) { chatEntry in
            NavigationStack {
                ChatView(
                    agent: chatEntry.gateway.cloudAgent,
                    sessionId: chatEntry.sessionId,
                    sessionKey: chatEntry.sessionKey,
                    sessionTitle: chatEntry.sessionTitle,
                    onDismiss: { activeChatEntry = nil }
                )
            }
        }
        .alert("删除代理？", isPresented: Binding(
            get: { deletingGateway != nil },
            set: { if !$0 { deletingGateway = nil } }
        )) {
            Button("删除", role: .destructive) {
                guard let deletingGateway else { return }
                ConnectionManager.shared.removeClient(agentId: deletingGateway.id)
                store.delete(id: deletingGateway.id)
                self.deletingGateway = nil
            }
            Button("取消", role: .cancel) {
                deletingGateway = nil
            }
        } message: {
            Text(deletingGateway?.name ?? "")
        }
    }

    private var agentsSection: some View {
        Section("代理") {
            ForEach(store.gateways) { gateway in
                Button {
                    activeGatewayForSessions = gateway
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(0.14),
                                                Color.clear,
                                                Color.blue.opacity(0.08)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )

                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.35),
                                        Color.white.opacity(0.05),
                                        Color.blue.opacity(0.25)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )

                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(.thinMaterial)
                                Image("OpenClawLogo")
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 24, height: 24)
                            }
                            .frame(width: 44, height: 44)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Color.white.opacity(0.25), lineWidth: 0.8)
                            )

                            VStack(alignment: .leading, spacing: 6) {
                                Text(gateway.name)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(gateway.wsURL)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }

                            Spacer()

                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                    }
                    .shadow(color: Color.blue.opacity(0.14), radius: 14, x: 0, y: 8)
                    .shadow(color: Color.black.opacity(0.08), radius: 6, x: 0, y: 3)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                .listRowBackground(Color.clear)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        deletingGateway = gateway
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        editingGateway = gateway
                    } label: {
                        Label("编辑", systemImage: "pencil")
                    }
                    .tint(.blue)
                }
            }
        }
    }

    private var emptyStateView: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 48)

                Button {
                    showingAddGateway = true
                } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 12) {
                            Image("OpenClawLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 46, height: 46)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("扫描 OpenClaw 网关")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text("扫码添加第一个 Agent")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()
                            Image(systemName: "qrcode.viewfinder")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.blue)
                        }

                        Text("支持 ws:// 或 wss://，支持二维码和手动输入。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.blue.opacity(0.2), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Text("首页仅展示 Agent 与最近活跃 Session。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)
            }
            .padding(.horizontal, 16)
        }
    }

    private var recentSessionsSection: some View {
        Section("最近活跃会话") {
            if recentSessions.isEmpty {
                Text("暂无最近会话")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            ForEach(recentSessions) { session in
                if let gateway = store.gateways.first(where: { $0.id == session.agentId }) {
                    Button {
                        let sessionKey = session.channelMetadataDict?["sessionKey"] as? String
                        activeChatEntry = ClawHomeChatEntry(
                            gateway: gateway,
                            sessionId: session.id,
                            sessionKey: sessionKey,
                            sessionTitle: session.title
                        )
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(session.title.isEmpty ? "未命名会话" : session.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)

                                Spacer()

                                Text(session.lastMessageTime.formatted(.relative(presentation: .named)))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }

                            Text(gateway.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if !session.preview.isEmpty {
                                Text(session.preview)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    private func loadRecentSessions() async {
        do {
            let allSessions = try await sessionRepository.getAllSessions(agentId: nil)
            let gatewayIds = Set(store.gateways.map(\.id))

            let openClawSessions = allSessions.filter { session in
                gatewayIds.contains(session.agentId) && session.tags.contains("openclaw")
            }

            await MainActor.run {
                recentSessions = Array(openClawSessions.prefix(20))
            }
        } catch {
            print("[ClawHome] Failed to load recent sessions: \(error)")
            await MainActor.run {
                recentSessions = []
            }
        }
    }
}

private struct ClawHomeChatEntry: Identifiable {
    let gateway: LocalOpenClawGateway
    let sessionId: String
    let sessionKey: String?
    let sessionTitle: String?

    var id: String {
        "\(gateway.id):\(sessionId)"
    }
}

private enum GatewayFormMode {
    case create
    case edit(LocalOpenClawGateway)
}

private struct GatewayFormView: View {
    let mode: GatewayFormMode
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var rawURL: String = ""
    @State private var showingScanner = false
    @State private var scannedPayload: String?

    @State private var validationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("网关") {
                    TextField("显示名称", text: $name)
                    TextField("wss://gateway.example/ws?secret=... 或 https://host/path", text: $rawURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                }

                Section {
                    Button("扫描二维码") {
                        showingScanner = true
                    }
                }

                if let validationMessage {
                    Section {
                        Text(validationMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        save()
                    }
                }
            }
        }
        .onAppear {
            if case .edit(let gateway) = mode {
                name = gateway.name
                rawURL = gateway.wsURL
            }
        }
        .sheet(isPresented: $showingScanner) {
            QRCodeScannerView(
                scannedURL: Binding(
                    get: { scannedPayload },
                    set: { newValue in
                        scannedPayload = newValue
                        guard let newValue else { return }

                        if let parsed = OpenClawGatewayURLParser.parse(raw: newValue) {
                            rawURL = parsed
                            validationMessage = nil
                        } else {
                            validationMessage = "扫描内容不是有效的 OpenClaw 网关地址。支持 ws/wss 与 http/https 控制地址。"
                        }
                    }
                ),
                agentType: "OpenClaw"
            )
        }
    }

    private var title: String {
        switch mode {
        case .create:
            return "添加网关"
        case .edit:
            return "编辑网关"
        }
    }

    private func save() {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = "OpenClaw \(Date().formatted(date: .omitted, time: .shortened))"
        let finalName = normalizedName.isEmpty ? fallbackName : normalizedName

        guard let parsedURL = OpenClawGatewayURLParser.parse(raw: rawURL) else {
            validationMessage = "请提供有效的网关地址。支持 ws://、wss://、http:// 或 https:// 控制地址。"
            return
        }

        validationMessage = nil
        onSave(finalName, parsedURL)
    }
}

#Preview {
    ClawHomeRootView()
}
