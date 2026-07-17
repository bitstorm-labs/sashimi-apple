import SwiftUI

// MARK: - Subtitle Overlay View

/// Draws the current VTT cue from SubtitleManager. Shared by the tvOS and
/// mobile players; size defaults match the tvOS 10-foot UI.
struct SubtitleOverlay: View {
    @ObservedObject var manager: SubtitleManager
    var fontSize: CGFloat = 42
    var bottomPadding: CGFloat = 80

    private var compact: Bool { fontSize <= 24 }

    var body: some View {
        VStack {
            Spacer()

            if let cue = manager.currentCue {
                Text(cue.text)
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, compact ? 12 : 24)
                    .padding(.vertical, compact ? 6 : 12)
                    .background(
                        Color.black.opacity(0.75)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: compact ? 8 : 12))
                    .padding(.bottom, bottomPadding)
                    .transition(.opacity)
                    .id(cue.id)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: manager.currentCue?.id)
        .allowsHitTesting(false)
    }
}
