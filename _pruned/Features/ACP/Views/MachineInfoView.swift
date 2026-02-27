//
//  MachineInfoView.swift
//  contextgo
//
//  Machine information and connection details
//  Shows server config, auth token, machine metadata from sessions
//

import SwiftUI
import UIKit

struct MachineInfoView: View {
    let agent: CloudAgent
    let sessions: [CLISession]

    @Environment(\.dismiss) private var dismiss
    @State private var showCopyToast = false
    @State private var copiedText = ""

    var body: some View {
        NavigationStack {
            List {
                // Server Connection
                Section("服务器连接") {
                    if let config = try? agent.cliRelayConfig(),
                       let serverURL = config.serverURL as String? {
                        copyableRow(
                            icon: "server.rack",
                            iconColor: .blue,
                            label: "ContextGo Server",
                            value: serverURL
                        )
                    }

                    if let config = try? agent.cliRelayConfig(),
                       let token = config.token {
                        copyableRow(
                            icon: "key.fill",
                            iconColor: .orange,
                            label: "Auth Token",
                            value: formatToken(token)
                        ) {
                            copyToClipboard(token, label: "Token")
                        }
                    }

                    if let config = try? agent.cliRelayConfig(),
                       config.secretKey != nil {
                        HStack {
                            Image(systemName: "lock.shield.fill")
                                .foregroundColor(.green)
                                .frame(width: 24)
                            Text("Master Secret")
                            Spacer()
                            Text("已存储")
                                .foregroundColor(.green)
                                .font(.system(size: 14))
                        }
                    }
                }

                // Machine Info (from first session metadata)
                if let machine = primaryMachine {
                    Section("机器信息") {
                        LabeledContent("主机名", value: machine.host)

                        if let platform = machine.platform {
                            LabeledContent("平台", value: platformDisplayName(platform))
                        }

                        LabeledContent("Machine ID") {
                            Text(formatId(machine.machineId))
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundColor(.secondary)
                        }

                        LabeledContent("CLI 版本", value: machine.version)

                        if let flavor = machine.flavor {
                            LabeledContent("AI 引擎", value: flavor.capitalized)
                        }
                    }
                }

                // Sessions Overview
                if !sessions.isEmpty {
                    Section("会话概览") {
                        LabeledContent("总会话数", value: "\(sessions.count)")
                        LabeledContent("活跃会话", value: "\(sessions.filter { $0.active }.count)")

                        ForEach(sessions.prefix(5)) { session in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(session.displayName)
                                        .font(.system(size: 14, weight: .medium))
                                    Spacer()
                                    SessionStatusView(status: session.sessionStatus)
                                }

                                Button {
                                    copyToClipboard(session.id, label: "Session ID")
                                } label: {
                                    HStack(spacing: 4) {
                                        Text("ID: \(formatId(session.id))")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        Image(systemName: "doc.on.doc")
                                            .font(.system(size: 10))
                                            .foregroundColor(.blue)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Bot Config
                Section("Bot 配置") {
                    LabeledContent("名称", value: agent.displayName)
                    LabeledContent("渠道", value: agent.type.capitalized)

                    copyableRow(
                        icon: "person.crop.circle",
                        iconColor: .purple,
                        label: "Bot ID",
                        value: formatId(agent.id)
                    ) {
                        copyToClipboard(agent.id, label: "Bot ID")
                    }
                }
            }
            .navigationTitle("连接信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        dismiss()
                    }
                }
            }
            .overlay(alignment: .top) {
                if showCopyToast {
                    ToastView(message: "已复制 \(copiedText)")
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Computed

    private var primaryMachine: CLISession.Metadata? {
        // Get metadata from the most recent active session
        sessions.first(where: { $0.active })?.metadata ?? sessions.first?.metadata
    }

    // MARK: - Helper Views

    private func copyableRow(
        icon: String,
        iconColor: Color,
        label: String,
        value: String,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            if let action = action {
                action()
            } else {
                copyToClipboard(value, label: label)
            }
        } label: {
            HStack {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .frame(width: 24)
                Text(label)
                    .foregroundColor(.primary)
                Spacer()
                Text(value)
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundColor(.blue)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func formatToken(_ token: String) -> String {
        if token.count > 20 {
            return String(token.prefix(8)) + "..." + String(token.suffix(4))
        }
        return token
    }

    private func formatId(_ id: String) -> String {
        if id.count > 16 {
            return String(id.prefix(8)) + "..." + String(id.suffix(6))
        }
        return id
    }

    private func platformDisplayName(_ platform: String) -> String {
        switch platform {
        case "darwin": return "macOS"
        case "win32": return "Windows"
        case "linux": return "Linux"
        default: return platform
        }
    }

    private func copyToClipboard(_ text: String, label: String) {
        UIPasteboard.general.string = text
        copiedText = label

        withAnimation(.spring(response: 0.3)) {
            showCopyToast = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation(.spring(response: 0.3)) {
                showCopyToast = false
            }
        }
    }
}

#Preview {
    MachineInfoView(
        agent: CloudAgent(
            id: "preview-id",
            name: "claude-code",
            displayName: "Claude Code",
            description: "Test",
            type: "claudecode",
            config: "{\"serverURL\":\"\(CoreServerDefaults.relayServerURL)\",\"token\":\"test-token\"}",
            permissions: "{}",
            status: "active",
            createdAt: Date(),
            updatedAt: Date()
        ),
        sessions: [.sample]
    )
}
