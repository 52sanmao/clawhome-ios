//
//  AnimatedBackground.swift
//  contextgo
//
//  Animated gradient background with floating particles
//

import SwiftUI

struct AnimatedBackground: View {
    @State private var moveGradient = false
    @State private var particles: [FloatingParticle] = []

    var body: some View {
        ZStack {
            // Animated gradient background
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.1),
                    Color(red: 0.0, green: 0.15, blue: 0.1),
                    Color(red: 0.05, green: 0.1, blue: 0.05),
                    Color(red: 0.0, green: 0.05, blue: 0.1)
                ],
                startPoint: moveGradient ? .topLeading : .bottomLeading,
                endPoint: moveGradient ? .bottomTrailing : .topTrailing
            )
            .ignoresSafeArea()
            .onAppear {
                withAnimation(
                    Animation.easeInOut(duration: 8.0)
                        .repeatForever(autoreverses: true)
                ) {
                    moveGradient.toggle()
                }
            }

            // Floating particles
            ForEach(particles) { particle in
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                particle.color.opacity(0.6),
                                particle.color.opacity(0.0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: particle.size / 2
                        )
                    )
                    .frame(width: particle.size, height: particle.size)
                    .position(particle.position)
                    .blur(radius: 8)
            }
        }
        .onAppear {
            generateParticles()
            startParticleAnimation()
        }
    }

    private func generateParticles() {
        particles = (0..<15).map { _ in
            FloatingParticle(
                position: CGPoint(
                    x: CGFloat.random(in: 0...UIScreen.main.bounds.width),
                    y: CGFloat.random(in: 0...UIScreen.main.bounds.height)
                ),
                size: CGFloat.random(in: 40...120),
                color: [Color.green, Color.cyan, Color.blue].randomElement()!
            )
        }
    }

    private func startParticleAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            withAnimation(.linear(duration: 0.05)) {
                for i in particles.indices {
                    // Slow floating motion
                    particles[i].position.x += particles[i].velocity.dx
                    particles[i].position.y += particles[i].velocity.dy

                    // Wrap around screen edges
                    let screenWidth = UIScreen.main.bounds.width
                    let screenHeight = UIScreen.main.bounds.height

                    if particles[i].position.x < -50 {
                        particles[i].position.x = screenWidth + 50
                    } else if particles[i].position.x > screenWidth + 50 {
                        particles[i].position.x = -50
                    }

                    if particles[i].position.y < -50 {
                        particles[i].position.y = screenHeight + 50
                    } else if particles[i].position.y > screenHeight + 50 {
                        particles[i].position.y = -50
                    }
                }
            }
        }
    }
}

struct FloatingParticle: Identifiable {
    let id = UUID()
    var position: CGPoint
    let size: CGFloat
    let color: Color
    let velocity: CGVector

    init(position: CGPoint, size: CGFloat, color: Color) {
        self.position = position
        self.size = size
        self.color = color
        self.velocity = CGVector(
            dx: CGFloat.random(in: -0.3...0.3),
            dy: CGFloat.random(in: -0.3...0.3)
        )
    }
}

#Preview {
    AnimatedBackground()
}
