//
//  UIRenderPerformance.swift
//  contextgo
//
//  Global UI rendering knobs for chat performance-sensitive surfaces.
//

import Foundation

enum UIRenderPerformance {
    // Default keeps current visual experience; enable by setting
    // UserDefaults key `ui.highPerformanceModeEnabled` to true.
    static let highPerformanceModeEnabled: Bool = {
        let key = "ui.highPerformanceModeEnabled"
        if UserDefaults.standard.object(forKey: key) == nil {
            return false
        }
        return UserDefaults.standard.bool(forKey: key)
    }()

    static var allowsDecorativeAnimation: Bool {
        !highPerformanceModeEnabled
    }

    static var allowsSpinnerAnimation: Bool {
        !highPerformanceModeEnabled
    }
}
