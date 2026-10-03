import SwiftUI

/// A brief message over the picture ("Lowering quality for your connection",
/// "Quality: 480p · 4 Mbps"), shown by both player surfaces from
/// `PlayerViewModel.playbackNotice`. Never takes touches or focus.
struct PlaybackNoticeBanner: View {
    let text: String

    #if os(tvOS)
    private let font = Font.system(size: 28, weight: .semibold)
    private let topPadding: CGFloat = 60
    #else
    private let font = Font.subheadline.weight(.semibold)
    private let topPadding: CGFloat = 70
    #endif

    var body: some View {
        VStack {
            Text(text)
                .font(font)
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(.top, topPadding)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .transition(.opacity)
        .accessibilityElement(children: .combine)
    }
}
