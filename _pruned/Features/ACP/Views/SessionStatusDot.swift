//
//  SessionStatusDot.swift
//  contextgo
//
//  Real-time status indicator for CLI relay sessions
//  Shows pulsing animation for thinking/permission states
//

import SwiftUI

struct SessionStatusDot: View {
    let color: Color
    let isPulsing: Bool

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 1.0

    var body: some View {
        ZStack {
            // Outer glow (only when pulsing)
            if isPulsing {
                Circle()
                    .fill(color.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .scaleEffect(pulseScale)
                    .opacity(pulseOpacity)
                    .animation(
                        .easeInOut(duration: 1.5).repeatForever(autoreverses: true),
                        value: pulseScale
                    )
            }

            // Main dot
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)
        }
        .onAppear {
            if isPulsing {
                pulseScale = 1.6
                pulseOpacity = 0.2
            }
        }
    }
}

struct SessionStatusView: View {
    let status: CLISession.SessionStatus

    var body: some View {
        HStack(spacing: 6) {
            SessionStatusDot(
                color: Color(hex: status.color),
                isPulsing: status.isPulsing
            )

            Text(status.text)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Color(hex: status.color))
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        SessionStatusView(status: .disconnected)
        SessionStatusView(status: .thinking)
        SessionStatusView(status: .waiting)
        SessionStatusView(status: .permissionRequired)
        SessionStatusView(status: .error)
    }
    .padding()
}
