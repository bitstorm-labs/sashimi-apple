import SwiftUI

/// YouTube identifier chip for cover art (top-left corner) — the red
/// `play.rectangle.fill` glyph the home hero already uses, in a compact pill so
/// a YouTube video in a landscape card (Continue Watching) reads as YouTube the
/// same way the hero does. Channel cards render as circular art and don't need
/// it. Sizing is parameterized so the 10-ft tvOS card can render larger than the
/// compact iOS card while keeping identical styling.
struct YouTubeBadge: View {
    var fontSize: CGFloat = 15
    var showWordmark: Bool = true
    var horizontalPadding: CGFloat = 8
    var verticalPadding: CGFloat = 4

    /// YouTube brand red, matching the home hero badge.
    private static let youTubeRed = Color(red: 230 / 255, green: 33 / 255, blue: 23 / 255)

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "play.rectangle.fill")
            if showWordmark {
                Text("YouTube")
            }
        }
        .font(.system(size: fontSize, weight: .semibold))
        .foregroundStyle(YouTubeBadge.youTubeRed)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(Color.black.opacity(0.6))
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    }
}
