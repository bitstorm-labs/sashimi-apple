import SwiftUI

/// The FinTV row on Home.
///
/// Metrics mirror ContinueWatchingRow — 40pt bold heading, 80pt horizontal
/// inset — so the row lines up with the ones above and below it. The card
/// spacing is the one deliberate departure; see the comment on it below.
struct ChannelsRow: View {
    let cards: [ChannelCard]
    let onTune: (ChannelCard) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Stations")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(SashimiTheme.textPrimary)
                .padding(.horizontal, 80)

            ScrollView(.horizontal, showsIndicators: false) {
                // Wider gap than the other rows on purpose. A channel card is
                // one filled surface with its text inside it, so at the usual
                // 40 the cards abut into a continuous band; Continue Watching
                // gets away with 40 because its titles sit outside the card and
                // the background shows through between them.
                LazyHStack(spacing: 64) {
                    ForEach(cards) { card in
                        ChannelCard_View(card: card) { onTune(card) }
                            .frame(width: 440)
                    }
                }
                .padding(.horizontal, 80)
                .padding(.vertical, 20)
            }
        }
    }
}
