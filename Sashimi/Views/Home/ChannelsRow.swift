import SwiftUI

/// The FinTV row on Home.
///
/// Metrics deliberately mirror ContinueWatchingRow — 40pt bold heading, 80pt
/// horizontal inset, 40pt card spacing. A row that does not line up with the
/// ones above and below it reads as broken even when each value is defensible
/// on its own.
struct ChannelsRow: View {
    let cards: [ChannelCard]
    let onTune: (ChannelCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("FinTV")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 80)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 40) {
                    ForEach(cards) { card in
                        ChannelCard_View(card: card) { onTune(card) }
                            .frame(width: 460)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 20)
            }
        }
    }
}
