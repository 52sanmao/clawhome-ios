//
//  BrainCenterView.swift
//  contextgo
//
//  Central brain component with breathing animation
//

import SwiftUI

struct BrainCenterView: View {
    @State private var isBreathing = false
    @State private var haloOpacity: Double = 0.3

    var body: some View {
        ZStack {
            // Outer halo (breathing)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.green.opacity(haloOpacity),
                            Color.cyan.opacity(haloOpacity * 0.5),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 40,
                        endRadius: 80
                    )
                )
                .frame(width: 160, height: 160)
                .scaleEffect(isBreathing ? 1.15 : 1.0)
                .opacity(haloOpacity)
                .animation(
                    Animation.easeInOut(duration: 2.0)
                        .repeatForever(autoreverses: true),
                    value: isBreathing
                )

            // Middle glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.green.opacity(0.4),
                            Color.green.opacity(0.1),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 30,
                        endRadius: 70
                    )
                )
                .frame(width: 140, height: 140)
                .blur(radius: 10)

            // Brain logo container (不旋转)
            ZStack {
                // Background circle
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 120, height: 120)

                // Logo
                Image("AppLogoSmall")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .scaleEffect(isBreathing ? 1.05 : 1.0)
            .animation(
                Animation.easeInOut(duration: 2.0)
                        .repeatForever(autoreverses: true),
                value: isBreathing
            )

            // Particle effects (optional - simplified version)
            ForEach(0..<8) { index in
                Circle()
                    .fill(Color.green.opacity(0.3))
                    .frame(width: 4, height: 4)
                    .offset(
                        x: cos(Double(index) * .pi / 4) * 80,
                        y: sin(Double(index) * .pi / 4) * 80
                    )
                    .opacity(isBreathing ? 0.0 : 0.6)
                    .scaleEffect(isBreathing ? 1.5 : 1.0)
                    .animation(
                        Animation.easeOut(duration: 1.5)
                            .repeatForever(autoreverses: false)
                            .delay(Double(index) * 0.1),
                        value: isBreathing
                    )
            }
        }
        .onAppear {
            isBreathing = true
            haloOpacity = 0.8
        }
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        BrainCenterView()
    }
}
