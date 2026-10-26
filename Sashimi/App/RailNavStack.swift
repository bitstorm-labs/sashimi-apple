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

extension View {
    /// Pins a section's view to the screen's height. The root ZStack sizes to
    /// its tallest child, and the rail beside the content is
    /// `maxHeight: .infinity`: a section whose content asked for more than
    /// 1080pt (Search with a full recent-search list asked for 1156pt) made
    /// the whole ZStack that tall, so the rail stretched, its flexible gaps
    /// (#740) spread the rows apart, and the stack re-centred — the
    /// "accordion" on selecting Search (#751).
    ///
    /// `height` is the full screen, safe areas included: the sections draw
    /// under the overscan margins (containerRelativeFrame would stop short).
    func railSectionFrame(height: CGFloat) -> some View {
        frame(height: height)
    }
}
