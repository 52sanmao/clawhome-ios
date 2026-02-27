//
//  ServerConfigSheet.swift
//  contextgo
//
//  服务器配置弹窗 — 配置上下文服务器地址和中继服务器地址

import SwiftUI

struct ServerConfigSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var config = CoreConfig.shared

    @State private var coreEndpoint: String = ""
    @State private var cliRelayServerURL: String = ""
    @State private var openClawGatewayURL: String = ""

    var body: some View {
        ZStack {
            LinearGradient(
                colors: colorScheme == .dark
                    ? [Color(red: 0.08, green: 0.09, blue: 0.11), Color(red: 0.12, green: 0.13, blue: 0.16)]
                    : [Color(.systemGray6), Color(.systemBackground)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("服务器配置")
                        .font(.title2).bold()
                        .foregroundColor(colorScheme == .dark ? .white : .primary)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundColor((colorScheme == .dark ? Color.white : Color.black).opacity(0.35))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 28)
                .padding(.bottom, 32)

                // Context Server
                configSection(
                    title: "上下文服务器",
                    description: "contextgo-core 服务地址",
                    placeholder: "https://core.example.com",
                    text: $coreEndpoint
                )

                Spacer().frame(height: 24)

                // Relay Server
                configSection(
                    title: "中继服务器",
                    description: "CLI 终端中继地址",
                    placeholder: "https://relay.example.com",
                    text: $cliRelayServerURL
                )

                Spacer().frame(height: 24)

                // OpenClaw Gateway
                configSection(
                    title: "OpenClaw 网关",
                    description: "OpenClaw WebSocket 网关地址",
                    placeholder: "ws://127.0.0.1:18789",
                    text: $openClawGatewayURL
                )

                Spacer()

                // Save button
                Button(action: save) {
                    Text("保存")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.95), Color.cyan.opacity(0.85)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
        .onAppear {
            coreEndpoint = config.endpoint
            cliRelayServerURL = config.cliRelayServerURL
            openClawGatewayURL = config.openClawGatewayURL
        }
    }

    private func configSection(title: String, description: String, placeholder: String, text: Binding<String>) -> AnyView {
        let titleColor: Color = colorScheme == .dark ? Color.white.opacity(0.78) : Color.primary.opacity(0.85)
        let descriptionColor: Color = colorScheme == .dark ? Color.white.opacity(0.45) : Color.secondary
        let fieldTextColor: Color = colorScheme == .dark ? Color.white : Color.primary
        let fieldBackground: Color = colorScheme == .dark ? Color.white.opacity(0.09) : Color.white
        let fieldBorder: Color = colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.08)
        let cardBackground: Color = colorScheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.92)
        let cardBorder: Color = colorScheme == .dark ? Color.white.opacity(0.14) : Color.black.opacity(0.08)

        return AnyView(VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundColor(titleColor)
            Text(description)
                .font(.caption2)
                .foregroundColor(descriptionColor)
            TextField(placeholder, text: text)
                .font(.system(size: 14))
                .foregroundColor(fieldTextColor)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .background(fieldBackground)
                .cornerRadius(10)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(fieldBorder, lineWidth: 1)
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardBorder, lineWidth: 1)
        )
        .padding(.horizontal, 24))
    }

    private func save() {
        let core = coreEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let relay = cliRelayServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let gateway = openClawGatewayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !core.isEmpty { config.endpoint = core }
        if !relay.isEmpty { config.cliRelayServerURL = relay }
        if !gateway.isEmpty { config.openClawGatewayURL = gateway }
        dismiss()
    }
}

#Preview {
    ServerConfigSheet()
}
