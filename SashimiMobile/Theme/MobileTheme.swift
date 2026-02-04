import SwiftUI

// MARK: - Colors (Shared with tvOS)

enum MobileColors {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let cardBackground = Color(white: 0.12)
    static let accent = Color(red: 0.36, green: 0.68, blue: 0.90)
    static let accentSecondary = Color(red: 0.95, green: 0.65, blue: 0.25)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.75)
    static let textTertiary = Color(white: 0.55)
    static let progressBackground = Color(white: 0.25)
    static let success = Color.green
    static let warning = Color.orange
    static let error = Color.red
    static let overlay = Color.black.opacity(0.7)
}

// MARK: - Corner Radius

enum MobileCornerRadius {
    static let small: CGFloat = 6
    static let medium: CGFloat = 8
    static let large: CGFloat = 12
    static let xl: CGFloat = 16
}

// MARK: - Animation

enum MobileAnimation {
    static let fast: Double = 0.15
    static let normal: Double = 0.25
    static let slow: Double = 0.4
    static let spring = SwiftUI.Animation.spring(response: 0.3, dampingFraction: 0.7)
}

// MARK: - Spacing (iPad-appropriate)

enum MobileSpacing {
    /// 24pt - Extra large spacing (screen edges, major sections)
    static let xl: CGFloat = 24
    /// 20pt - Large spacing (between sections)
    static let lg: CGFloat = 20
    /// 16pt - Medium spacing (between related elements)
    static let md: CGFloat = 16
    /// 12pt - Small spacing (within components)
    static let sm: CGFloat = 12
    /// 8pt - Extra small spacing (tight layouts)
    static let xs: CGFloat = 8
    /// 4pt - Minimal spacing
    static let xxs: CGFloat = 4
}

// MARK: - Typography (iPad-scaled from tvOS)

enum MobileTypography {
    // Display sizes - for hero sections (tvOS: 76/56 → iPad: 34/28)
    static let displayLarge: Font = .system(size: 34, weight: .bold)
    static let displayMedium: Font = .system(size: 28, weight: .bold)

    // Headlines - for section titles (tvOS: 40/32 → iPad: 22/20)
    static let headline: Font = .system(size: 22, weight: .bold)
    static let headlineSmall: Font = .system(size: 20, weight: .semibold)

    // Titles - for card titles, list items (tvOS: 28/24 → iPad: 17/15)
    static let title: Font = .system(size: 17, weight: .semibold)
    static let titleSmall: Font = .system(size: 15, weight: .medium)

    // Body - for descriptions, metadata (tvOS: 24/20 → iPad: 15/14)
    static let body: Font = .system(size: 15)
    static let bodySmall: Font = .system(size: 14)

    // Caption - for secondary info (tvOS: 18/16 → iPad: 13/12)
    static let caption: Font = .system(size: 13)
    static let captionSmall: Font = .system(size: 12)
}

// MARK: - Sizing (iPad-appropriate)

enum MobileSizing {
    /// Minimum tappable area (Apple HIG: 44pt)
    static let minTappableSize: CGFloat = 44

    // Card sizes (tvOS: 220x330 → iPad: 140x210)
    static let posterWidth: CGFloat = 140
    static let posterHeight: CGFloat = 210

    // Landscape cards (tvOS: 320x180 → iPad: 220x124)
    static let landscapeCardWidth: CGFloat = 220
    static let landscapeCardHeight: CGFloat = 124

    // Continue watching cards (larger for prominence)
    static let continueWatchingWidth: CGFloat = 280
    static let continueWatchingHeight: CGFloat = 158

    // Icon sizes
    static let iconSmall: CGFloat = 16
    static let iconMedium: CGFloat = 20
    static let iconLarge: CGFloat = 28

    // Hero section
    static let heroHeight: CGFloat = 400
    static let heroTitleSize: CGFloat = 40
}

// MARK: - Poster Aspect Ratios

enum PosterAspectRatio {
    static let portrait: CGFloat = 2 / 3  // 0.667 - movie posters
    static let landscape: CGFloat = 16 / 9  // 1.778 - backdrops
    static let square: CGFloat = 1
}
