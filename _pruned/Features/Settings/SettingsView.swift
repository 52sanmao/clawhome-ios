//
//  SettingsView.swift
//  contextgo
//
//  Unified settings entry
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var coreConfig = CoreConfig.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showServerConfig = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text("统一管理 Core、CLI Relay 与 OpenClaw Gateway 地址。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    Button {
                        showServerConfig = true
                    } label: {
                        HStack {
                            Image(systemName: "network")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("服务器地址")
                                    .foregroundColor(.primary)
                                Text("Core / Relay / OpenClaw Gateway")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    NavigationLink(destination: CoreSettingsView()) {
                        HStack {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                                .foregroundColor(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Core 登录与认证")
                                Text(coreConfig.isConfigured ? coreConfig.endpoint : "未登录")
                                    .font(.caption)
                                    .foregroundColor(coreConfig.isConfigured ? .secondary : .orange)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Image(systemName: coreConfig.isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle")
                                .foregroundColor(coreConfig.isConfigured ? .green : .orange)
                                .font(.caption)
                        }
                    }
                } header: {
                    Text("服务器与认证")
                } footer: {
                    Text("地址配置与账号认证已拆分：地址统一在“服务器地址”，认证在“Core 登录与认证”。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("当前地址")
                            .font(.caption.bold())
                        Text("Core: \(coreConfig.endpoint)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("Relay: \(coreConfig.cliRelayServerURL)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        Text("OpenClaw: \(coreConfig.openClawGatewayURL)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("关于 ContextGo")
                            .font(.headline)
                        Text("掌控你的上下文，释放 AI 潜能")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("连接本地知识与大语言模型的关键桥梁。安全地管理你的私有上下文，并通过标准协议服务于任何 AI 智能体。")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.top, 4)
                    }
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") {
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showServerConfig) {
                ServerConfigSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(.regularMaterial)
            }
        }
    }
}

#Preview {
    SettingsView()
}
