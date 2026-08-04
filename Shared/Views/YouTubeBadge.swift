import SwiftUI

/// YouTube identifier for cover art (top-left corner) — the red
/// `play.rectangle.fill` glyph, matching the home hero. On cards it's the glyph
/// alone (no wordmark), like the Roku badge, so a YouTube video in a landscape
/// card (Continue Watching) reads as YouTube without a bulky label. Channel
/// cards render as circular art and don't need it. `showWordmark` is opt-in for
/// contexts that want the full "YouTube" pill.
struct YouTubeBadge: View {
    var glyphSize: CGFloat = 26
    var showWordmark: Bool = false

    /// YouTube brand red, matching the home hero badge.
    private static let youTubeRed = Color(red: 230 / 255, green: 33 / 255, blue: 23 / 255)

    var body: some View {
        if showWordmark {
            HStack(spacing: 5) {
                Image(systemName: "play.rectangle.fill")
                Text("YouTube")
            }
            .font(.system(size: glyphSize * 0.6, weight: .semibold))
            .foregroundStyle(YouTubeBadge.youTubeRed)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.black.opacity(0.6))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        } else {
            // Glyph only. A drop shadow keeps it legible over bright thumbnails
            // without a pill; play.rectangle.fill already reads as the YouTube mark.
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: glyphSize))
                .foregroundStyle(YouTubeBadge.youTubeRed)
                .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
        }
    }
}
