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
    /// A floor only for genuinely tiny items (a 5-minute short). Anything
    /// larger stays strictly proportional: a generous floor made every block
    /// the same width, which turns the ruler above them into a lie, and pushed
    /// the row wider than its frame so SwiftUI centred it and clipped the first
    /// block off-screen.
    private let minimumBlockWidth: CGFloat = 60

    private let rowHeight: CGFloat = 92

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
            LazyVStack(alignment: .leading, spacing: 26) {
                ForEach(viewModel.rows) { row in
                    VStack(alignment: .leading, spacing: 8) {
                        channelLabel(row)
                        channelRow(row)
                    }
                }
            }
            .padding(.bottom, 80)
        }
    }

    private func channelLabel(_ row: GuideRow) -> some View {
        Text(row.channel.name.uppercased())
            .font(.system(size: 22, weight: .heavy))
            .tracking(1.4)
            .foregroundStyle(SashimiTheme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(SashimiTheme.cardBackground))
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
    }

    private func channelRow(_ row: GuideRow) -> some View {
        // Deliberately the same shape as every other row in the app: a
        // horizontal ScrollView of focusable cards inside a focus section.
        // The aligned-timeline grid this replaces was a vertical scroll view
        // containing a horizontal one containing an HStack, and focus could
        // not be moved into it at all. A guide that cannot be selected is
        // worth less than one whose columns do not line up perfectly.
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: blockSpacing) {
                ForEach(row.channel.programs) { entry in
                    GuideBlock(
                        row: row,
                        entry: entry,
                        width: width(for: entry),
                        onSelect: { select(row: row, entry: entry) }
                    )
                }
            }
            .padding(.horizontal, 80)
            .padding(.vertical, 8)
        }
        .focusSection()
    }

    // MARK: - Geometry

    private let blockSpacing: CGFloat = 6

    private var totalWidth: CGFloat { CGFloat(viewModel.hours * 60) * pointsPerMinute }

    /// Proportional to the part of the programme that falls inside the window.
    ///
    /// The guide deliberately includes the programme straddling the right-hand
    /// edge, so drawing it at full length made every row wider than the ruler.
    /// An overflowing HStack gets centred, which pushed the leftmost block —
    /// the one actually airing — off the screen. Trimming at the edge is also
    /// what a real guide does.
    private func width(for entry: GuideEntry) -> CGFloat {
        let visibleEnd = min(entry.endUtc, windowEnd)
        let visibleStart = max(entry.startUtc, windowStart)
        let minutes = max(0, visibleEnd.timeIntervalSince(visibleStart) / 60)
        return max(minimumBlockWidth, CGFloat(minutes) * pointsPerMinute - blockSpacing)
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

/// A future programme the viewer asked about.
struct GuideSelection: Identifiable, Equatable {
    let row: GuideRow
    let entry: GuideEntry
    var id: String { "\(row.id)-\(entry.id)" }
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
