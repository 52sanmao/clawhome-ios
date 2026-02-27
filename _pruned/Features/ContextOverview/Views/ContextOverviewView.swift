//
//  ContextOverviewView.swift
//  contextgo
//
//  Context overview page showing brain center with orbiting nodes
//

import SwiftUI

struct ContextOverviewView: View {
    @State private var appeared = false
    @State private var activeNodeIndex: Int = 0
    @State private var dashPhase: CGFloat = 0
    @State private var logoAppeared = false
    @State private var subtitleAppeared = false

    let nodes = ContextNode.sampleNodes
    let orbitRadius: CGFloat = 120  // 缩小半径从180到120

    var body: some View {
        ZStack {
            // Animated background
            AnimatedBackground()

            VStack(spacing: 0) {
                // Top banner - logo with slogan
                VStack(spacing: 12) {
                    Image("ContextOverviewLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 60)
                        .scaleEffect(logoAppeared ? 1 : 0.5)
                        .opacity(logoAppeared ? 1 : 0)
                        .rotationEffect(.degrees(logoAppeared ? 0 : 180))

                    Text("掌控你的上下文 · 释放 AI 潜能")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white.opacity(0.8))
                        .opacity(subtitleAppeared ? 1 : 0)
                        .offset(y: subtitleAppeared ? 0 : 10)
                }
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity)
                .background(
                    LinearGradient(
                        colors: [
                            Color.green.opacity(0.15),
                            Color.green.opacity(0.05)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Main content
                GeometryReader { geometry in
                    let center = CGPoint(
                        x: geometry.size.width / 2,
                        y: geometry.size.height / 2
                    )

                    ZStack {
                    // Connection lines
                    ForEach(nodes.indices, id: \.self) { index in
                        let node = nodes[index]
                        let nodePos = nodePosition(for: node, center: center)
                        // node 放大时半径也变大
                        let currentNodeRadius: CGFloat = (index == activeNodeIndex) ? 36 : 30
                        // 计算连接线起点（从 node 边缘开始，不重叠）
                        let lineStart = calculateLineStart(from: nodePos, to: center, nodeRadius: currentNodeRadius)
                        // 计算连接线终点（到中心 logo 边缘）
                        let lineEnd = calculateLineEnd(from: nodePos, to: center, centerRadius: 40)

                        ConnectionLine(
                            from: lineStart,
                            to: lineEnd,
                            color: node.color,
                            dashPhase: dashPhase,
                            isActive: node.isActive,
                            isHighlighted: index == activeNodeIndex
                        )
                        .opacity(appeared ? (node.isActive ? 0.4 : 0.2) : 0)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: activeNodeIndex)
                    }

                    // Orbit path (subtle guide)
                    Circle()
                        .stroke(Color.white.opacity(0.05), lineWidth: 1)
                        .frame(width: orbitRadius * 2, height: orbitRadius * 2)
                        .position(center)

                    // Orbiting nodes (固定位置,顺序放大)
                    ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                        OrbitNodeView(
                            node: node,
                            orbitRotation: 0,  // 不旋转
                            isHighlighted: index == activeNodeIndex
                        )
                        .position(nodePosition(for: node, center: center))
                        .opacity(appeared ? 1 : 0)
                        .scaleEffect(appeared ? (index == activeNodeIndex ? 1.2 : 1.0) : 0)
                        .animation(
                            .spring(response: 0.5, dampingFraction: 0.7)
                                .delay(Double(index) * 0.1),
                            value: appeared
                        )
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: activeNodeIndex)
                    }

                    // Central brain (不旋转)
                    BrainCenterView()
                        .position(center)
                        .opacity(appeared ? 1 : 0)
                        .scaleEffect(appeared ? 1 : 0.5)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: appeared)
                    }
                }
                .background(
                    LinearGradient(
                        colors: [
                            Color.green.opacity(0.02),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Logo animation
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7)) {
                logoAppeared = true
            }

            // Slogan animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                withAnimation(.spring(response: 0.5, dampingFraction: 0.75)) {
                    subtitleAppeared = true
                }
            }

            // Trigger entrance animation
            appeared = true

            // Start sequential highlight animation after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                startSequentialAnimation()
            }

            // Start connection line pulse
            withAnimation(
                Animation.linear(duration: 1.5)
                    .repeatForever(autoreverses: false)
            ) {
                dashPhase = 10
            }
        }
    }

    // MARK: - Helper Methods

    /// Calculate node position on orbit (固定位置)
    private func nodePosition(for node: ContextNode, center: CGPoint) -> CGPoint {
        let angleRadians = node.angle * .pi / 180  // 移除orbitRotation
        let x = center.x + orbitRadius * cos(angleRadians)
        let y = center.y + orbitRadius * sin(angleRadians)
        return CGPoint(x: x, y: y)
    }

    /// Calculate line start point (从 node 边缘开始)
    private func calculateLineStart(from nodePos: CGPoint, to center: CGPoint, nodeRadius: CGFloat) -> CGPoint {
        let dx = center.x - nodePos.x
        let dy = center.y - nodePos.y
        let distance = sqrt(dx * dx + dy * dy)
        let ratio = nodeRadius / distance
        return CGPoint(
            x: nodePos.x + dx * ratio,
            y: nodePos.y + dy * ratio
        )
    }

    /// Calculate line end point (到中心 logo 边缘)
    private func calculateLineEnd(from nodePos: CGPoint, to center: CGPoint, centerRadius: CGFloat) -> CGPoint {
        let dx = center.x - nodePos.x
        let dy = center.y - nodePos.y
        let distance = sqrt(dx * dx + dy * dy)
        let ratio = (distance - centerRadius) / distance
        return CGPoint(
            x: nodePos.x + dx * ratio,
            y: nodePos.y + dy * ratio
        )
    }

    /// Start sequential node highlight animation
    private func startSequentialAnimation() {
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { timer in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                activeNodeIndex = (activeNodeIndex + 1) % nodes.count
            }
        }
    }
}

// MARK: - Connection Line
struct ConnectionLine: View {
    let from: CGPoint
    let to: CGPoint
    let color: Color
    let dashPhase: CGFloat
    let isActive: Bool
    let isHighlighted: Bool

    var body: some View {
        Path { path in
            path.move(to: from)
            path.addLine(to: to)
        }
        .stroke(
            LinearGradient(
                colors: [color, Color.green],
                startPoint: .init(x: from.x, y: from.y),
                endPoint: .init(x: to.x, y: to.y)
            ),
            style: StrokeStyle(
                lineWidth: isHighlighted ? 4 : (isActive ? 2 : 1),  // 放大时更粗
                dash: [5, 5],
                dashPhase: dashPhase
            )
        )
        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: isHighlighted)
    }
}

// MARK: - Preview
#Preview {
    NavigationView {
        ContextOverviewView()
    }
}
