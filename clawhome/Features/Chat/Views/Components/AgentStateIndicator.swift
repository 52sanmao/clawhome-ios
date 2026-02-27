//
//  AgentStateIndicator.swift
//  contextgo
//
//  Displays agent lifecycle state (thinking, responding, error, compacting)
//

import SwiftUI

struct AgentStateIndicator: View {
    let state: ChatViewModel.AgentState

    var body: some View {
        switch state {
        case .idle:
            EmptyView()

        case .thinking:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                    .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                Text("思考中…")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.blue.opacity(0.1))
            .cornerRadius(16)

        case .responding:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.8)
                    .progressViewStyle(CircularProgressViewStyle(tint: .green))
                Text("生成中…")
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.green.opacity(0.1))
            .cornerRadius(16)

        case .stopped(let reason):
            HStack(spacing: 8) {
                Image(systemName: "stop.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                Text(reason.map { "已停止：\($0)" } ?? "已停止")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.12))
            .cornerRadius(16)

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                Text("错误：\(message)")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.red.opacity(0.1))
            .cornerRadius(16)

        case .compacting(let status):
            HStack(spacing: 8) {
                Image(systemName: "arrow.3.trianglepath")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)
                    .rotationEffect(.degrees(360))
                    .animation(.linear(duration: 2).repeatForever(autoreverses: false), value: state)
                Text(status)
                    .font(.system(size: 14))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.orange.opacity(0.1))
            .cornerRadius(16)
        }
    }
}

// MARK: - Preview

struct AgentStateIndicator_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 16) {
            AgentStateIndicator(state: .idle)
            AgentStateIndicator(state: .thinking)
            AgentStateIndicator(state: .responding)
            AgentStateIndicator(state: .stopped("用户中断"))
            AgentStateIndicator(state: .error("Network timeout"))
            AgentStateIndicator(state: .compacting("正在整理上下文…"))
        }
        .padding()
        .previewLayout(.sizeThatFits)
    }
}
