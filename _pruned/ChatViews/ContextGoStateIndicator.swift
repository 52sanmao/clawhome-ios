//
//  ContextGoStateIndicator.swift
//  contextgo
//
//  ContextGo 链接状态指示器，显示在输入框上方
//

import SwiftUI

struct ContextGoStateIndicator: View {
    let isConnected: Bool
    let connectedSpaceCount: Int
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // Status dot
                Circle()
                    .fill(isConnected ? Color.green : Color.gray)
                    .frame(width: 8, height: 8)

                // Text
                if isConnected {
                    Text("已连接 ContextGO")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.primary)

                    if connectedSpaceCount > 0 {
                        Text("·")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)

                        Text("\(connectedSpaceCount) 个空间")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("未连接")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                }

                // Chevron
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(colorScheme == .dark ? Color(.systemGray6) : Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(
                        isConnected ? Color.green.opacity(0.3) : Color.gray.opacity(0.2),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    VStack(spacing: 20) {
        ContextGoStateIndicator(
            isConnected: true,
            connectedSpaceCount: 3,
            onTap: { print("Tapped") }
        )

        ContextGoStateIndicator(
            isConnected: true,
            connectedSpaceCount: 0,
            onTap: { print("Tapped") }
        )

        ContextGoStateIndicator(
            isConnected: false,
            connectedSpaceCount: 0,
            onTap: { print("Tapped") }
        )
    }
    .padding()
}
