import SwiftUI

// MARK: - Subtitle Overlay View

struct SubtitleOverlay: View {
    @ObservedObject var manager: SubtitleManager

    var body: some View {
        VStack {
            Spacer()

            if let cue = manager.currentCue {
                Text(cue.text)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        Color.black.opacity(0.75)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 80)
                    .transition(.opacity)
                    .id(cue.id)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: manager.currentCue?.id)
        .allowsHitTesting(false)
    }
}
