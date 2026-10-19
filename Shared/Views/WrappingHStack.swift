import SwiftUI

/// A horizontal row that wraps onto further lines when its children don't fit
/// the proposed width, instead of overflowing (and clipping, or widening the
/// whole detail column).
///
/// When everything fits it lays out like an `HStack` with the same spacing and
/// centre alignment, so existing rows look unchanged. Each child is kept whole:
/// a child is moved to the next line rather than squeezed.
struct WrappingHStack: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat

    init(spacing: CGFloat = 8, lineSpacing: CGFloat = 6) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = measure(subviews, maxWidth: proposal.width)
        let lines = Self.lines(widths: sizes.map(\.width), maxWidth: proposal.width ?? .infinity, spacing: spacing)
        var width: CGFloat = 0
        var height: CGFloat = 0
        for (index, line) in lines.enumerated() {
            width = max(width, lineWidth(line, sizes))
            height += lineHeight(line, sizes) + (index > 0 ? lineSpacing : 0)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = measure(subviews, maxWidth: bounds.width)
        let lines = Self.lines(widths: sizes.map(\.width), maxWidth: bounds.width, spacing: spacing)
        var y = bounds.minY
        for line in lines {
            let height = lineHeight(line, sizes)
            var x = bounds.minX
            for index in line {
                let size = sizes[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += height + lineSpacing
        }
    }

    /// Splits children of the given widths into lines no wider than
    /// `maxWidth`. A child wider than `maxWidth` gets a line of its own.
    static func lines(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [Range<Int>] {
        var lines: [Range<Int>] = []
        var start = 0
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if index > start, used + spacing + width > maxWidth {
                lines.append(start..<index)
                start = index
                used = width
            } else {
                used += (index > start ? spacing : 0) + width
            }
        }
        if start < widths.count {
            lines.append(start..<widths.count)
        }
        return lines
    }

    /// Ideal sizes, with any child wider than the row capped to the row width.
    private func measure(_ subviews: Subviews, maxWidth: CGFloat?) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard let maxWidth, ideal.width > maxWidth else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
        }
    }

    private func lineWidth(_ line: Range<Int>, _ sizes: [CGSize]) -> CGFloat {
        line.reduce(0) { $0 + sizes[$1].width } + spacing * CGFloat(max(line.count - 1, 0))
    }

    private func lineHeight(_ line: Range<Int>, _ sizes: [CGSize]) -> CGFloat {
        line.map { sizes[$0].height }.max() ?? 0
    }
}
