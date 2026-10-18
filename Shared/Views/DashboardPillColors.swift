import SwiftUI

// The Server dashboard's stream-card pill colours, the same on every client
// (sashimi-roku `AdminDash.pills`, the mockup's OpsDec palette). The play-mode
// pill takes the badge's colour from each platform's theme instead.
extension DashboardPillKind {
    /// Text colour; nil for `.mode`.
    var foreground: Color? {
        switch self {
        case .resolution: return Color(hex: 0x6CC6F0)
        case .video: return Color(hex: 0xB79CF5)
        case .audio: return Color(hex: 0xF2C46B)
        case .bitrate: return Color(hex: 0x5FD3C4)
        case .mode: return nil
        }
    }

    /// Fill; nil for `.mode`.
    var background: Color? {
        switch self {
        case .resolution: return Color(hex: 0x15303F)
        case .video: return Color(hex: 0x2A2140)
        case .audio: return Color(hex: 0x3A2D12)
        case .bitrate: return Color(hex: 0x123331)
        case .mode: return nil
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}
