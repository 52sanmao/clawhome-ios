//
//  OrbitNodeView.swift
//  contextgo
//
//  Orbit node view representing a device or data source
//

import SwiftUI

struct OrbitNodeView: View {
    let node: ContextNode
    let orbitRotation: Double  // Current orbit rotation angle
    var isHighlighted: Bool = false  // 是否高亮

    var body: some View {
        VStack(spacing: 4) {
            // Icon container
            ZStack {
                // Background circle
                Circle()
                    .fill(node.color.opacity(isHighlighted ? 0.3 : 0.15))
                    .frame(width: 60, height: 60)

                // Icon
                Image(systemName: node.icon)
                    .font(.system(size: 32))
                    .foregroundColor(node.color)

                // Active indicator
                if node.isActive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(Color.white, lineWidth: 2)
                        )
                        .offset(x: 20, y: -20)
                }
            }

            // Name label
            Text(node.name)
                .font(.system(size: 12, weight: isHighlighted ? .semibold : .medium))
                .foregroundColor(isHighlighted ? .white : .white.opacity(0.7))
        }
        // Counter-rotate to keep upright
        .rotationEffect(.degrees(-orbitRotation))
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.black.ignoresSafeArea()

        VStack(spacing: 40) {
            // Active node
            OrbitNodeView(
                node: ContextNode(
                    icon: "airpodspro",
                    name: "耳机",
                    color: .blue,
                    angle: 0,
                    isActive: true
                ),
                orbitRotation: 0
            )

            // Inactive node
            OrbitNodeView(
                node: ContextNode(
                    icon: "vision.pro",
                    name: "眼镜",
                    color: .purple,
                    angle: 45,
                    isActive: false
                ),
                orbitRotation: 0
            )
        }
    }
}
