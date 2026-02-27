//
//  TechBackgroundView.swift
//  contextgo
//
//  Animated tech-style background with particles and grid
//

import SwiftUI

struct TechBackgroundView: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var particleOffsets: [CGSize] = Array(repeating: .zero, count: 20)
    @State private var gridRotation: Double = 0
    @State private var glowPulse: CGFloat = 1.0
    @State private var waveOffset: CGFloat = 0

    var body: some View {
        ZStack {
            // Base gradient - adaptive for dark/light mode
            LinearGradient(
                colors: colorScheme == .dark ? [
                    Color(hex: "1A1A1A"),
                    Color(hex: "0F1419"),
                    Color(hex: "0A0E14")
                ] : [
                    Color(hex: "F5F7FA"),
                    Color(hex: "E8EDF5"),
                    Color(hex: "D1DCF0")
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Floating particles
            GeometryReader { geometry in
                ForEach(0..<20, id: \.self) { index in
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    particleColor(for: index).opacity(particleOpacity(for: 0.3)),
                                    particleColor(for: index).opacity(particleOpacity(for: 0.1))
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: particleSize(for: index), height: particleSize(for: index))
                        .blur(radius: 2)
                        .offset(particleOffsets[index])
                        .position(
                            x: particleInitialX(for: index, width: geometry.size.width),
                            y: particleInitialY(for: index, height: geometry.size.height)
                        )
                }
            }

            // Grid pattern overlay - brighter in dark mode
            GeometryReader { geometry in
                ZStack {
                    // Horizontal lines
                    ForEach(0..<15, id: \.self) { index in
                        Rectangle()
                            .fill(Color.blue.opacity(colorScheme == .dark ? 0.08 : 0.03))
                            .frame(height: 1)
                            .offset(y: CGFloat(index) * geometry.size.height / 15)
                    }

                    // Vertical lines
                    ForEach(0..<10, id: \.self) { index in
                        Rectangle()
                            .fill(Color.cyan.opacity(colorScheme == .dark ? 0.08 : 0.03))
                            .frame(width: 1)
                            .offset(x: CGFloat(index) * geometry.size.width / 10)
                    }
                }
                .opacity(0.5)
            }

            // Radial glow effects - enhanced in dark mode
            RadialGradient(
                colors: [
                    Color.blue.opacity(colorScheme == .dark ? 0.15 : 0.08),
                    Color.clear
                ],
                center: .topLeading,
                startRadius: 0,
                endRadius: 400
            )
            .scaleEffect(glowPulse)
            .blur(radius: 60)

            RadialGradient(
                colors: [
                    Color.cyan.opacity(colorScheme == .dark ? 0.12 : 0.06),
                    Color.clear
                ],
                center: .bottomTrailing,
                startRadius: 0,
                endRadius: 500
            )
            .scaleEffect(glowPulse)
            .blur(radius: 80)

            // Animated wave overlay
            GeometryReader { geometry in
                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let waveHeight: CGFloat = 30

                    path.move(to: CGPoint(x: 0, y: height * 0.3))

                    for x in stride(from: 0, through: width, by: 1) {
                        let relativeX = x / width
                        let sine = sin((relativeX + waveOffset) * .pi * 4) * waveHeight
                        path.addLine(to: CGPoint(x: x, y: height * 0.3 + sine))
                    }
                }
                .stroke(
                    LinearGradient(
                        colors: colorScheme == .dark ? [
                            Color.blue.opacity(0.25),
                            Color.cyan.opacity(0.2),
                            Color.purple.opacity(0.15)
                        ] : [
                            Color.blue.opacity(0.15),
                            Color.cyan.opacity(0.1),
                            Color.purple.opacity(0.08)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 2
                )
                .blur(radius: 1)

                Path { path in
                    let width = geometry.size.width
                    let height = geometry.size.height
                    let waveHeight: CGFloat = 25

                    path.move(to: CGPoint(x: 0, y: height * 0.7))

                    for x in stride(from: 0, through: width, by: 1) {
                        let relativeX = x / width
                        let sine = sin((relativeX - waveOffset * 0.7) * .pi * 3) * waveHeight
                        path.addLine(to: CGPoint(x: x, y: height * 0.7 + sine))
                    }
                }
                .stroke(
                    LinearGradient(
                        colors: colorScheme == .dark ? [
                            Color.purple.opacity(0.2),
                            Color.blue.opacity(0.15),
                            Color.cyan.opacity(0.12)
                        ] : [
                            Color.purple.opacity(0.1),
                            Color.blue.opacity(0.08),
                            Color.cyan.opacity(0.06)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 2
                )
                .blur(radius: 1)
            }

            // Tech corner accents
            VStack {
                HStack {
                    TechCornerAccent()
                    Spacer()
                    TechCornerAccent()
                        .rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                }
                Spacer()
                HStack {
                    TechCornerAccent()
                        .rotation3DEffect(.degrees(180), axis: (x: 1, y: 0, z: 0))
                    Spacer()
                    TechCornerAccent()
                        .rotation3DEffect(.degrees(180), axis: (x: 1, y: 1, z: 0))
                }
            }
            .padding(20)
        }
        .ignoresSafeArea()
        .onAppear {
            startAnimations()
        }
    }

    private func startAnimations() {
        // Animate particles
        for index in 0..<20 {
            let randomDuration = Double.random(in: 8...15)
            let randomX = CGFloat.random(in: -50...50)
            let randomY = CGFloat.random(in: -50...50)

            withAnimation(
                .easeInOut(duration: randomDuration)
                .repeatForever(autoreverses: true)
                .delay(Double(index) * 0.2)
            ) {
                particleOffsets[index] = CGSize(width: randomX, height: randomY)
            }
        }

        // Pulse glow
        withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
            glowPulse = 1.3
        }

        // Wave animation
        withAnimation(.linear(duration: 8).repeatForever(autoreverses: false)) {
            waveOffset = 1.0
        }
    }

    private func particleSize(for index: Int) -> CGFloat {
        let sizes: [CGFloat] = [8, 12, 16, 20, 24]
        return sizes[index % sizes.count]
    }

    private func particleColor(for index: Int) -> Color {
        let colors: [Color] = [.blue, .cyan, .purple, .indigo]
        return colors[index % colors.count]
    }

    // Adaptive particle opacity based on color scheme
    private func particleOpacity(for baseOpacity: Double) -> Double {
        colorScheme == .dark ? baseOpacity * 1.5 : baseOpacity
    }

    private func particleInitialX(for index: Int, width: CGFloat) -> CGFloat {
        CGFloat((index * 73) % 100) / 100.0 * width
    }

    private func particleInitialY(for index: Int, height: CGFloat) -> CGFloat {
        CGFloat((index * 97) % 100) / 100.0 * height
    }
}

// MARK: - Tech Corner Accent
struct TechCornerAccent: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: colorScheme == .dark ? [
                            Color.blue.opacity(0.5),
                            Color.cyan.opacity(0.25)
                        ] : [
                            Color.blue.opacity(0.3),
                            Color.cyan.opacity(0.1)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 40, height: 2)

            HStack(spacing: 4) {
                Rectangle()
                    .fill(Color.blue.opacity(colorScheme == .dark ? 0.5 : 0.3))
                    .frame(width: 2, height: 20)

                Rectangle()
                    .fill(Color.cyan.opacity(colorScheme == .dark ? 0.4 : 0.2))
                    .frame(width: 2, height: 15)

                Rectangle()
                    .fill(Color.blue.opacity(colorScheme == .dark ? 0.3 : 0.15))
                    .frame(width: 2, height: 10)
            }
        }
    }
}

#Preview {
    TechBackgroundView()
}
