import SwiftUI

/// The FinTV guide: channels down, time across.
struct GuideView: View {
    var onBackAtRoot: (() -> Void)?
    var focusNamespace: Namespace.ID?

    @StateObject private var viewModel = GuideViewModel()
    @State private var tuned: TunedChannel?
    @State private var selected: GuideSelection?
    @State private var windowStart = Date()

    /// Horizontal scale. At 9pt a three-hour window is ~1620pt, which fits the
    /// safe area without horizontal scrolling — scrolling sideways on a remote
    /// to read a schedule is miserable.
    private let pointsPerMinute: CGFloat = 9

    /// Below this a title is unreadable. Strict proportionality would render a
    /// 22-minute sitcom at a fifth the width of a film, and a guide you cannot
    /// read defeats the point; the distortion is small across three hours.
    private let minimumBlockWidth: CGFloat = 150

    private let channelColumnWidth: CGFloat = 230
    private let rowHeight: CGFloat = 104

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
                    Color.clear.frame(height: 40)   // aligns with the time ruler
                    ForEach(viewModel.rows) { row in
                        channelLabel(row)
                            .frame(width: channelColumnWidth, height: rowHeight, alignment: .leading)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 12) {
                            timeRuler
                            ForEach(viewModel.rows) { row in
                                channelRow(row)
                            }
                        }
                        nowLine
                    }
                }
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 80)
        }
    }

    private func channelLabel(_ row: GuideRow) -> some View {
        Text(row.channel.name.uppercased())
            .font(.system(size: 19, weight: .heavy))
            .tracking(1.1)
            .foregroundStyle(SashimiTheme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Capsule().fill(SashimiTheme.cardBackground))
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
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
        HStack(spacing: 6) {
            ForEach(row.channel.programs) { entry in
                GuideBlock(
                    row: row,
                    entry: entry,
                    width: width(for: entry),
                    onSelect: { select(row: row, entry: entry) }
                )
            }
            // Channels differ in how far their schedule reaches; without this
            // the shorter rows end mid-grid and the ruler stops lining up.
            Spacer(minLength: 0)
        }
        .frame(width: totalWidth, height: rowHeight, alignment: .leading)
    }

    private var nowLine: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Rectangle()
                .fill(SashimiTheme.accent)
                .frame(width: 3)
                .offset(x: offset(for: context.date) + channelColumnWidth * 0)
                .opacity(context.date >= windowStart ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Geometry

    private var totalWidth: CGFloat { CGFloat(viewModel.hours * 60) * pointsPerMinute }

    private func offset(for date: Date) -> CGFloat {
        CGFloat(date.timeIntervalSince(windowStart) / 60) * pointsPerMinute
    }

    private func width(for entry: GuideEntry) -> CGFloat {
        max(minimumBlockWidth, CGFloat(entry.duration / 60) * pointsPerMinute)
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
