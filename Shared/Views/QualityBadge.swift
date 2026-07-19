import SwiftUI

/// Resolution chip shown on cover art (top-left corner). Style B: the top tier
/// ("4K") glows Jellyfin purple to draw the eye to the best copies, while "HD"
/// and "SD" sit on dark translucent slate. Driven by `BaseItemDto.qualityBadge`.
///
/// Sizing is parameterized so the 10-ft tvOS grid can render larger than the
/// compact iOS grid while keeping identical styling.
struct QualityBadge: View {
    let label: String
    var fontSize: CGFloat = 12
    var horizontalPadding: CGFloat = 6
    var verticalPadding: CGFloat = 3
    var cornerRadius: CGFloat = 6

    /// Matches the sidebar logo / accent (#BD3EED).
    private static let jellyfinPurple = Color(red: 189 / 255, green: 62 / 255, blue: 237 / 255)

    private var isTopTier: Bool { label == "4K" }

    var body: some View {
        Text(label)
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(isTopTier ? QualityBadge.jellyfinPurple : Color.black.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}
