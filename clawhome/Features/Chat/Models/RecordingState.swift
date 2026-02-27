//
//  RecordingState.swift
//  contextgo
//
//  Recording state machine and configuration
//

import Foundation
import SwiftUI

// MARK: - Input Mode
/// 输入模式
enum InputMode: Equatable {
    case text       // 文字输入模式
    case voice      // 语音输入模式（显示"按住说话"按钮）
}

// MARK: - Recording State
/// 录音状态机 (简化版)
/// - idle: 空闲（文字输入态）
/// - recording: 录音中（点击开始，点击停止/取消）
enum RecordingState: Equatable {
    case idle
    case recording

    // Legacy states for backward compatibility (map to recording)
    static let recordingUnlocked: RecordingState = .recording
    static let recordingLocked: RecordingState = .recording
    static let recordingPaused: RecordingState = .recording
}

// MARK: - Animation Configuration
struct AnimationConfig {
    // Input width animation
    static let inputWidthDuration: Double = 0.25
    static let inputWidthAnimation = Animation.easeInOut(duration: 0.25)

    // Button fade animation
    static let buttonFadeDuration: Double = 0.2
    static let buttonAppearDelay: Double = 0.1
    static let buttonSpring = Animation.spring(response: 0.3, dampingFraction: 0.7)

    // Recording transition animation
    static let recordingTransitionDuration: Double = 0.3
    static let recordingSpring = Animation.spring(response: 0.4, dampingFraction: 0.7)

    // Indicator animation
    static let indicatorDuration: Double = 1.2
    static let indicatorAnimation = Animation.easeInOut(duration: 1.2).repeatForever(autoreverses: true)

    // Cancel hint animation
    static let cancelHintDuration: Double = 0.2
    static let cancelHintDisplayTime: Double = 1.0
}

// MARK: - Input Dimensions
struct InputDimensions {
    static let horizontalPadding: CGFloat = 16
    static let inputSpacing: CGFloat = 12
    static let recordButtonSize: CGFloat = 44
    static let sendButtonSize: CGFloat = 32
    static let inputMinHeight: CGFloat = 40
    static let inputCornerRadius: CGFloat = 20
}

// MARK: - Recording Control Layout
struct RecordingControlLayout {
    static let timerFontSize: CGFloat = 28
    static let timerIconSize: CGFloat = 20
    static let lockIconSize: CGFloat = 24
    static let arrowHeight: CGFloat = 40
    // Upward swipe target position (relative)
    static let lockPosition: CGFloat = -80
    // Left swipe cancel threshold
    static let cancelThreshold: CGFloat = -100
}

// MARK: - Gesture Configuration
struct GestureConfig {
    // Long press minimum duration (300ms)
    static let longPressMinDuration: Double = 0.3
    static let longPressAllowableMovement: CGFloat = 10
}
