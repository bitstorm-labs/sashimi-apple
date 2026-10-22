import SwiftUI

/// The rail's nav rows, stacked with a gap that gives way when the screen runs
/// out of height.
///
/// The gap is 26pt whenever there is room. Each library a server adds is
/// another row, and a fixed gap let the column outgrow the 1080pt screen: the
/// rail then measured taller than the screen and the root ZStack centred it,
/// lifting the logo — and every other view in that ZStack — off the top edge.
/// Here the gaps are spacers capped at 26pt, so a long nav closes them down
/// toward `minSpacing` instead. Give this stack a higher layout priority than
/// the spacers around it so it keeps its full gaps whenever the column fits.
struct RailNavStack<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    @ViewBuilder let row: (Data.Element) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(data.enumerated()), id: \.element.id) { index, element in
                if index > 0 {
                    Spacer(minLength: RailNavSpacing.min)
                        .frame(maxHeight: RailNavSpacing.max)
                }
                row(element)
            }
        }
    }
}

enum RailNavSpacing {
    static let max: CGFloat = 26
    static let min: CGFloat = 4
}
