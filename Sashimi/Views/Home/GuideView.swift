import SwiftUI

/// The FinTV guide: channels down, time across.
struct GuideView: View {
    var onBackAtRoot: (() -> Void)?
    var focusNamespace: Namespace.ID?

    @StateObject private var viewModel = GuideViewModel()
    @State private var tuned: TunedChannel?
    @State private var selected: GuideSelection?
    @State private var windowStart = Date()

    /// Horizontal scale. Three hours at 7.5pt is 1350pt, which fits beside the
    /// rail and the channel column with nothing to scroll sideways — which is
    /// the point: a horizontal scroll view nested inside a vertical one is
    /// exactly the arrangement tvOS focus handles worst, and scrolling sideways
    /// on a remote to read a schedule is miserable anyway.
    private let pointsPerMinute: CGFloat = 7.5

    /// Below this a title is unreadable. Strict proportionality would render a
    /// 22-minute sitcom at a fifth the width of a film, and a guide you cannot
    /// read defeats the point; the distortion is small across three hours.
    /// A floor only for genuinely tiny items. A generous one made every short
    /// block the same width and near-square, which both looks like a strip of
    /// tiles and quietly turns the ruler above them into a lie.
    private let minimumBlockWidth: CGFloat = 60

    /// Wide enough for the longest channel name plus two lines of its
    /// description. The timeline still fits beside it without scrolling
    /// sideways: 340 + 1350 + 160pt of inset is 1850 of 1920.
    private let channelColumnWidth: CGFloat = 340
    private let rowHeight: CGFloat = 88

    private var windowEnd: Date { windowStart.addingTimeInterval(viewModel.hours * 3600) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if viewModel.isLoading {
                ProgressView().padding(.horizontal, 80).padding(.top, 40)
            } else if viewModel.rows.isEmpty {
                emptyState
            } else {
                grid
            }
            Spacer(minLength: 0)
        }
        .background(SashimiTheme.background)
        .task {
            await viewModel.load()
            // Refresh on the minute so the now-line and the current-programme
            // highlight stay honest without redrawing constantly.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
                guard !Task.isCancelled else { break }
                windowStart = Date()
                await viewModel.load()
            }
        }
        .fullScreenCover(item: $tuned) { tuned in
            PlayerView(item: tuned.item, channelContext: tuned.context)
        }
        .fullScreenCover(item: $selected) { selection in
            GuideDetailView(row: selection.row, entry: selection.entry)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Guide")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(SashimiTheme.textPrimary)
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(SashimiTheme.textSecondary)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 60)
        .padding(.bottom, 24)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(viewModel.loadFailed ? "Couldn't reach the server" : "No channels yet")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(SashimiTheme.textPrimary)
            Text(viewModel.loadFailed
                 ? "The guide needs the server to be reachable."
                 : "Channels are created in Jellyfin under Dashboard → Plugins → Channels.")
                .font(.system(size: 22))
                .foregroundStyle(SashimiTheme.textSecondary)
        }
        .padding(.horizontal, 80)
        .padding(.top, 40)
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                // Channel names sit outside the scrolling timeline so they stay
                // put while the schedule moves.
                VStack(alignment: .leading, spacing: 12) {
                    // Width is mandatory: Color.clear is greedy, and without it
                    // this spacer expands to fill, taking the whole row's width
                    // and shoving the timeline off to the right.
                    Color.clear.frame(width: channelColumnWidth, height: 40)
                    ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                        channelLabel(row, index: index)
                            .frame(width: channelColumnWidth, height: rowHeight, alignment: .leading)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    timeRuler
                    ForEach(viewModel.rows) { row in
                        channelRow(row)
                    }
                }
                // Overlay rather than a ZStack sibling: a bare Rectangle in a
                // ZStack has no intrinsic height and stretched the stack.
                .overlay(alignment: .topLeading) { nowLine }
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 80)
        }
    }

    /// Name over its description, against a colour rail.
    ///
    /// A channel is not just a label: what it *is* stays true as programmes
    /// come and go, and the grid to the right only ever says what is on. The
    /// name alone in a grey capsule left the column carrying none of that.
    private func channelLabel(_ row: GuideRow, index: Int) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // The rail runs in row order rather than being derived from the
            // channel's identity, so the palette reads as an index down the
            // screen and neighbouring channels never land on the same colour.
            RoundedRectangle(cornerRadius: 2)
                .fill(Self.railColour(at: index))
                .frame(width: 4)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 5) {
                Text(row.channel.name.uppercased())
                    .font(.system(size: 21, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(SashimiTheme.textPrimary)
                    .lineLimit(1)

                if let description = row.channel.description, !description.isEmpty {
                    Text(description)
                        .font(.system(size: 15))
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .lineLimit(2)
                        // Without this a two-line string is given one line's
                        // height and clipped, because the row's height is fixed.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.trailing, 24)
    }

    /// Rail colours, cycled by row. Deliberately no purple: that is the accent
    /// the grid uses for what is on now, and a channel wearing it would read as
    /// a state rather than an identity.
    private static let railPalette: [Color] = [
        Color(red: 0.30, green: 0.78, blue: 0.80),
        Color(red: 0.95, green: 0.65, blue: 0.25),
        Color(red: 0.93, green: 0.36, blue: 0.48),
        Color(red: 0.40, green: 0.80, blue: 0.50),
        Color(red: 0.36, green: 0.68, blue: 0.90),
        Color(red: 0.88, green: 0.78, blue: 0.35)
    ]

    private static func railColour(at index: Int) -> Color {
        railPalette[index % railPalette.count]
    }

    /// Half-hour ticks across the window.
    private var timeRuler: some View {
        let firstTick = windowStart.nextHalfHour
        let ticks = stride(from: 0, through: Int(viewModel.hours * 2), by: 1).map {
            firstTick.addingTimeInterval(Double($0) * 1800)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(ticks, id: \.timeIntervalSince1970) { tick in
                Text(tick.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(SashimiTheme.textTertiary)
                    .offset(x: offset(for: tick))
            }
        }
        .frame(width: totalWidth, height: 40, alignment: .topLeading)
    }

    private func channelRow(_ row: GuideRow) -> some View {
        let isFirstRow = viewModel.rows.first?.id == row.id
        return HStack(spacing: 6) {
            ForEach(Array(row.channel.programs.enumerated()), id: \.element.id) { index, entry in
                GuideBlock(
                    row: row,
                    entry: entry,
                    width: width(for: entry),
                    onSelect: { select(row: row, entry: entry) }
                )
                // Something has to claim the beam when the screen appears, or
                // focus stays in the rail and the grid cannot be reached at all.
                .defaultFocus(in: isFirstRow && index == 0 ? focusNamespace : nil)
            }
            // Channels differ in how far their schedule reaches; without this
            // the shorter rows end mid-grid and the ruler stops lining up.
            Spacer(minLength: 0)
        }
        .frame(width: totalWidth, height: rowHeight, alignment: .leading)
        // Each row competes for the focus beam on its own, so up/down moves
        // between channels rather than the whole grid behaving as one target.
        .focusSection()
    }

    private var nowLine: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Rectangle()
                .fill(SashimiTheme.accent)
                .frame(width: 3, height: gridHeight)
                .offset(x: offset(for: context.date))
                .opacity(context.date >= windowStart ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    /// Explicit because the line is an overlay: ruler, then a row and its gap
    /// for each channel.
    private var gridHeight: CGFloat {
        40 + CGFloat(viewModel.rows.count) * (rowHeight + 12)
    }

    // MARK: - Geometry

    private var totalWidth: CGFloat { CGFloat(viewModel.hours * 60) * pointsPerMinute }

    private func offset(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(windowStart) / 60) * pointsPerMinute
    }

    /// Proportional to the part of the programme inside the window. The guide
    /// includes the one straddling the right-hand edge, and drawing it at full
    /// length pushes the row wider than the ruler.
    private func width(for entry: GuideEntry) -> CGFloat {
        let visibleEnd = min(entry.endUtc, windowEnd)
        let visibleStart = max(entry.startUtc, windowStart)
        let minutes = max(0, visibleEnd.timeIntervalSince(visibleStart) / 60)
        return max(minimumBlockWidth, CGFloat(minutes) * pointsPerMinute - 6)
    }

    // MARK: - Actions

    private func select(row: GuideRow, entry: GuideEntry) {
        // Only what is on right now can be tuned to; anything later opens its
        // detail instead, because you cannot watch what has not aired.
        guard entry.isAiring(at: Date()) else {
            selected = GuideSelection(row: row, entry: entry)
            return
        }
        Task {
            guard let result = await viewModel.tuneIn(to: row.channel.id),
                  let item = try? await JellyfinClient.shared.getItem(itemId: result.itemID) else {
                await viewModel.load()
                return
            }
            tuned = TunedChannel(item: item, context: result.context)
        }
    }
}

private extension Date {
    /// The next :00 or :30 at or after this instant, so the ruler reads in
    /// round numbers rather than starting at whatever minute it happens to be.
    var nextHalfHour: Date {
        let interval: TimeInterval = 1800
        return Date(timeIntervalSince1970: (timeIntervalSince1970 / interval).rounded(.up) * interval)
    }
}

private extension View {
    /// `prefersDefaultFocus` only when a namespace is supplied, matching how
    /// Home claims focus for its hero. Without a namespace (previews) this is
    /// a no-op.
    @ViewBuilder
    func defaultFocus(in namespace: Namespace.ID?) -> some View {
        if let namespace {
            prefersDefaultFocus(true, in: namespace)
        } else {
            self
        }
    }
}
