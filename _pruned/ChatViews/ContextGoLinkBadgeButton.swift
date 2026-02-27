//
//  ContextGoLinkBadgeButton.swift
//  contextgo
//
//  Reusable "Agent × ContextGo" link badge with connected-space count.
//

import SwiftUI

struct ContextGoLinkBadgeButton: View {
    let agentLogoName: String
    let isLinked: Bool
    let connectedSpaceCount: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(agentLogoName)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .opacity(isLinked ? 1.0 : 0.5)

                Text("×")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(isLinked ? .green : .secondary)

                Image("AppLogoSmall")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 18, height: 18)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .opacity(isLinked ? 1.0 : 0.5)

                Circle()
                    .fill(
                        isLinked
                        ? LinearGradient(colors: [Color.green, Color.cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(width: 4, height: 4)
                    .scaleEffect(isLinked ? 1.2 : 1.0)
                    .opacity(isLinked ? 0.85 : 0.6)
                    .animation(
                        isLinked
                        ? Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                        : .default,
                        value: isLinked
                    )

                if isLinked && connectedSpaceCount > 0 {
                    Text("\(connectedSpaceCount)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Capsule()
                                .fill(Color.green)
                        )
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isLinked ? Color.green.opacity(0.08) : Color(.systemGray5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isLinked ? Color.green.opacity(0.2) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.22), value: isLinked)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: connectedSpaceCount)
    }
}

