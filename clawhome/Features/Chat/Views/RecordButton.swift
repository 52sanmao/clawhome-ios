//
//  RecordButton.swift
//  contextgo
//
//  Hold-to-record button with drag gesture support
//

import SwiftUI

struct RecordButton: View {
    @Binding var recordingState: RecordingState

    let onStartRecording: () -> Void
    let onCancelRecording: () -> Void
    let onSendRecording: () -> Void

    @State private var isPressed = false
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(isPressed ? 0.2 : 0.1))
                .frame(width: InputDimensions.recordButtonSize, height: InputDimensions.recordButtonSize)
                .scaleEffect(isPressed ? 1.1 : 1.0)

            Image(systemName: "mic.fill")
                .font(.system(size: 20))
                .foregroundColor(.blue)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isPressed {
                        // Start recording immediately when touch begins
                        isPressed = true
                        onStartRecording()

                        let impact = UIImpactFeedbackGenerator(style: .medium)
                        impact.impactOccurred()
                    }

                    dragOffset = value.translation

                    // Cancel if dragged too far (e.g., more than 100 points up)
                    if dragOffset.height < -100 {
                        isPressed = false
                        dragOffset = .zero
                        onCancelRecording()

                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                    }
                }
                .onEnded { value in
                    if isPressed {
                        isPressed = false
                        dragOffset = .zero

                        // Send recording if released normally
                        if value.translation.height > -100 {
                            onSendRecording()

                            let impact = UIImpactFeedbackGenerator(style: .heavy)
                            impact.impactOccurred()
                        }
                    }
                }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isPressed)
    }
}

#Preview {
    RecordButton(
        recordingState: .constant(.idle),
        onStartRecording: { print("Start") },
        onCancelRecording: { print("Cancel") },
        onSendRecording: { print("Send") }
    )
    .padding()
}
