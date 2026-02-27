//
//  LaunchScreenView.swift
//  contextgo
//
//  App Launch Screen with Logo and Loading Animation
//

import SwiftUI

struct LaunchScreenView: View {
    @State private var isAnimating = false
    @State private var logoScale: CGFloat = 0.8
    @State private var logoOpacity: Double = 0.0
    @StateObject private var bgEngine = LaunchBackgroundEngine()

    var body: some View {
        ZStack {
            // Animated particle background (same as MainAppView)
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

            VStack(spacing: 40) {
                // Logo with rounded corners
                Image("ContextGoLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: .white.opacity(0.3), radius: 20, x: 0, y: 0)
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)
                    .onAppear {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                            logoScale = 1.0
                            logoOpacity = 1.0
                        }
                    }

                // Loading Animation
                LoadingRing()
                    .frame(width: 40, height: 40)
                    .opacity(logoOpacity)
            }
        }
    }
}

// MARK: - Background Particle Engine (Same as MainAppView)

struct LaunchParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    var velocity: CGVector
    var radius: CGFloat
    var opacity: Double
    var blur: CGFloat
}

class LaunchBackgroundEngine: ObservableObject {
    var particles: [LaunchParticle] = []

    func setup(size: CGSize) {
        guard particles.isEmpty else { return }
        for _ in 0..<40 {
            let p = LaunchParticle(
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

// MARK: - Loading Ring Animation

struct LoadingRing: View {
    @State private var isRotating = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(
                LinearGradient(
                    colors: [.white, .white.opacity(0.3)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
            .rotationEffect(.degrees(isRotating ? 360 : 0))
            .onAppear {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    isRotating = true
                }
            }
    }
}

// Alternative: Pulsing Dots Loading Animation
struct LoadingDots: View {
    @State private var animatingDot1 = false
    @State private var animatingDot2 = false
    @State private var animatingDot3 = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .scaleEffect(animatingDot1 ? 1.0 : 0.5)
                .opacity(animatingDot1 ? 1.0 : 0.3)

            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .scaleEffect(animatingDot2 ? 1.0 : 0.5)
                .opacity(animatingDot2 ? 1.0 : 0.3)

            Circle()
                .fill(Color.white)
                .frame(width: 8, height: 8)
                .scaleEffect(animatingDot3 ? 1.0 : 0.5)
                .opacity(animatingDot3 ? 1.0 : 0.3)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                animatingDot1 = true
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                    animatingDot2 = true
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                withAnimation(.easeInOut(duration: 0.6).repeatForever()) {
                    animatingDot3 = true
                }
            }
        }
    }
}

#Preview {
    LaunchScreenView()
}
