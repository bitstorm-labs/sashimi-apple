import SwiftUI

/// A centred column for Settings pages on iPad and Mac (#904). A grouped List
/// or Form fills the whole detail area, so in landscape every row, button and
/// text field ran ~1100pt wide. The column is made with scroll-content margins
/// rather than a frame, so the list still scrolls from anywhere on the page.
enum ReadableColumn {
    /// Widest the column gets: about a phone in landscape.
    static let maxWidth: CGFloat = 680

    /// About the margin an inset-grouped list already has on iPad.
    static let systemMargin: CGFloat = 20

    /// The side margin that centres a `maxWidth` column in `containerWidth`,
    /// or nil when that would be no wider than the list's own margin (iPhone,
    /// a narrow iPad split view): the list keeps its system margins then.
    static func horizontalMargin(containerWidth: CGFloat, maxWidth: CGFloat = maxWidth) -> CGFloat? {
        let margin = ((containerWidth - maxWidth) / 2).rounded(.down)
        return margin > systemMargin ? margin : nil
    }
}

private struct ReadableColumnModifier: ViewModifier {
    @State private var containerWidth: CGFloat = 0

    func body(content: Content) -> some View {
        content
            // nil keeps the list's own system margins.
            .contentMargins(.horizontal, ReadableColumn.horizontalMargin(containerWidth: containerWidth), for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
    }
}

extension View {
    /// Keeps a Settings List or Form to a centred readable column on iPad
    /// and Mac. No effect where the screen is narrower than the column.
    func readableSettingsColumn() -> some View {
        modifier(ReadableColumnModifier())
    }
}
