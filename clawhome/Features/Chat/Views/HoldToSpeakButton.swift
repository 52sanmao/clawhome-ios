//
//  HoldToSpeakButton.swift
//  contextgo
//
//  Hold-to-speak button for voice input mode
//

import SwiftUI

struct HoldToSpeakButton: View {
    @Binding var isHolding: Bool
    let onHoldStart: () -> Void
    let onHoldEnd: () -> Void
    var isEnabled: Bool = true  // NEW: enable/disable state

    @State private var pressScale: CGFloat = 1.0
    @State private var wasHolding: Bool = false  // ✅ 追踪上一次的状态

    var body: some View {
        Text(isHolding ? "松开 发送" : "按住 说话")
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(isEnabled ? (isHolding ? .white : .blue) : .gray.opacity(0.5))
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(isEnabled ? (isHolding ? Color.blue : Color.blue.opacity(0.1)) : Color.gray.opacity(0.1))
            )
            .scaleEffect(pressScale)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // ✅ 不直接修改状态，只在首次触发时调用回调
                        // 状态由 ViewModel 管理
                        if !isHolding && isEnabled {
                            print("🎤 [BUTTON] onChanged - 调用 onHoldStart()")
                            pressScale = 0.95
                            onHoldStart()  // ViewModel 会设置 isHoldingSpeakButton = true

                            let impact = UIImpactFeedbackGenerator(style: .medium)
                            impact.impactOccurred()
                        }
                    }
                    .onEnded { gesture in
                        // ✅ 不直接修改状态，只在释放时调用回调
                        // 状态由 ViewModel 管理
                        if isHolding && isEnabled {
                            print("🎤 [BUTTON] onEnded - 手势结束位置: \(gesture.location)")
                            print("🎤 [BUTTON] onEnded - 调用 onHoldEnd()")
                            pressScale = 1.0
                            onHoldEnd()  // ViewModel 会设置 isHoldingSpeakButton = false

                            let impact = UIImpactFeedbackGenerator(style: .light)
                            impact.impactOccurred()
                        }
                    }
            )
            // ❌ Removed onDisappear - it causes premature recording end when view hierarchy changes
            // The button view gets removed when isHoldingSpeakButton=true (ChatInputBar shows Spacer instead)
            // This would trigger onDisappear and force-end the recording
            .onChange(of: isHolding) { newValue in
                // ✅ 监听状态变化，确保 UI 同步
                print("🎤 [BUTTON] onChange - isHolding: \(wasHolding) -> \(newValue)")
                wasHolding = newValue

                // 重置缩放效果
                if !newValue {
                    pressScale = 1.0
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pressScale)
            .allowsHitTesting(isEnabled)  // Disable interaction when not enabled
    }
}

#Preview {
    VStack(spacing: 20) {
        HoldToSpeakButton(
            isHolding: .constant(false),
            onHoldStart: { print("Hold start") },
            onHoldEnd: { print("Hold end") }
        )
        .padding()

        HoldToSpeakButton(
            isHolding: .constant(true),
            onHoldStart: { print("Hold start") },
            onHoldEnd: { print("Hold end") }
        )
        .padding()
    }
}
