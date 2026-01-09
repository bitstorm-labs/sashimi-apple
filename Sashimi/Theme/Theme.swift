import SwiftUI

// MARK: - Colors

enum SashimiTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let cardBackground = Color(white: 0.12)
    static let accent = Color(red: 0.36, green: 0.68, blue: 0.90)
    static let accentSecondary = Color(red: 0.95, green: 0.65, blue: 0.25)
    static let highlight = Color(red: 0.36, green: 0.68, blue: 0.90)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.75)
    static let textTertiary = Color(white: 0.55)
    static let focusGlow = Color(red: 0.36, green: 0.68, blue: 0.90).opacity(0.5)
    static let progressBackground = Color(white: 0.25)
}

// MARK: - Spacing

enum Spacing {
    /// 80pt - Extra large spacing (screen edges, major sections)
    static let xl: CGFloat = 80
    /// 60pt - Large spacing (between sections)
    static let lg: CGFloat = 60
    /// 40pt - Medium spacing (between related elements)
    static let md: CGFloat = 40
    /// 20pt - Small spacing (within components)
    static let sm: CGFloat = 20
    /// 10pt - Extra small spacing (tight layouts)
    static let xs: CGFloat = 10
    /// 4pt - Minimal spacing
    static let xxs: CGFloat = 4
}

// MARK: - Typography

enum Typography {
    // Display sizes - for hero sections
    static let displayLarge: Font = .system(size: 76, weight: .bold)
    static let displayMedium: Font = .system(size: 56, weight: .bold)

    // Headlines - for section titles
    static let headline: Font = .system(size: 40, weight: .bold)
    static let headlineSmall: Font = .system(size: 32, weight: .semibold)

    // Titles - for card titles, list items
    static let title: Font = .system(size: 28, weight: .semibold)
    static let titleSmall: Font = .system(size: 24, weight: .medium)

    // Body - for descriptions, metadata
    static let body: Font = .system(size: 24)
    static let bodySmall: Font = .system(size: 20)

    // Caption - for secondary info
    static let caption: Font = .system(size: 18)
    static let captionSmall: Font = .system(size: 16)
}

// MARK: - Sizing (10-foot UI minimums)

enum Sizing {
    /// Minimum focusable element width
    static let minFocusableWidth: CGFloat = 120
    /// Minimum focusable element height
    static let minFocusableHeight: CGFloat = 80

    // Card sizes
    static let posterWidth: CGFloat = 220
    static let posterHeight: CGFloat = 330
    static let landscapeCardWidth: CGFloat = 320
    static let landscapeCardHeight: CGFloat = 180

    // Icon sizes
    static let iconSmall: CGFloat = 24
    static let iconMedium: CGFloat = 32
    static let iconLarge: CGFloat = 48
}
