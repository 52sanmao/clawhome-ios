import SwiftUI

// MARK: - Adaptive Theme Colors

struct ThemeColors {
    let colorScheme: ColorScheme

    // Background colors
    var primaryBackground: Color {
        colorScheme == .dark ? .black : .white
    }

    var secondaryBackground: Color {
        colorScheme == .dark ? Color(white: 0.1) : Color(white: 0.95)
    }

    var cardBackground: Color {
        colorScheme == .dark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)
    }

    var inputBackground: Color {
        colorScheme == .dark ? Color(white: 0.15) : Color(white: 0.92)
    }

    // Text colors
    var primaryText: Color {
        colorScheme == .dark ? .white : .black
    }

    var secondaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.6) : Color.black.opacity(0.6)
    }

    var tertiaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.4) : Color.black.opacity(0.4)
    }

    // Border colors
    var border: Color {
        colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.1)
    }

    var borderStrong: Color {
        colorScheme == .dark ? Color.white.opacity(0.15) : Color.black.opacity(0.15)
    }

    // Agent avatar colors (keep muted in both modes)
    var agentColors: [Color] {
        colorScheme == .dark ? [
            Color(white: 0.3),
            Color(white: 0.4),
            Color(white: 0.25),
            Color(white: 0.35)
        ] : [
            Color(white: 0.5),
            Color(white: 0.6),
            Color(white: 0.45),
            Color(white: 0.55)
        ]
    }

    // Accent colors remain consistent
    var accentBlue: Color { .blue }
    var accentOrange: Color { .orange }
    var accentGreen: Color { .green }
}

extension View {
    func adaptiveTheme(_ colorScheme: ColorScheme) -> ThemeColors {
        ThemeColors(colorScheme: colorScheme)
    }
}
