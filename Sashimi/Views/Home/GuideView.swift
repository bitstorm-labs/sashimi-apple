import SwiftUI

/// The SashimiTV guide: channels down, what's on across.
///
/// Each channel is a strip of fixed-width cards — what is on now, then what
/// follows — dealt out three to a page and paged per row. Fixed widths mean
/// the columns line up, so Up and Down keep the viewer in the same slot and
/// the in-progress card is always the first one. Nothing slides and nothing
/// is clipped; both are what made the time-proportional grid this replaced
/// unusable on a remote.
struct GuideView: View {
    var onBackAtRoot: (() -> Void)?
    var focusNamespace: Namespace.ID?

    @StateObject private var viewModel = GuideViewModel(hours: 168)
    @State private var tuned: TunedChannel?
    @State private var selected: GuideSelection?

    /// Each row's first visible programme, by channel id. Per row on purpose:
    /// one shared position is what carried other rows' first cards — the ones
    /// airing now — off the screen and out of the focus engine's reach.
    @State private var offsets: [String: Int] = [:]
    @FocusState private var focusedCard: CardID?
    /// Which jump chip is lit. Nil is "Now", which is also where every row
    /// opens; jumping turns each row to the page holding that instant.
    @State private var jump: String?
    @State private var showReminders = false
    @ObservedObject private var reminders = StationReminders.shared
    /// Bumped every minute so "min left" and the Now highlight stay honest
    /// without refetching a week of guide.
    @State private var minute = Date()

    private struct CardID: Hashable {
        let row: String
        let entry: String
    }

    /// Wide enough for the longest channel name plus two lines of its
    /// description.
    private let channelColumnWidth: CGFloat = 340
    /// Three cards, both page-turn buttons and the channel column fit inside
    /// the 1800pt beside the rail with the 80pt insets: 340 + 3×370 + 2×12 +
    /// 2×(56+12) = 1610. The buttons are always present, so this is the
    /// row's width, not its worst case.
    private let cardWidth: CGFloat = 370
    private let cardGap: CGFloat = 12
    private let turnWidth: CGFloat = 56
    /// The card's 72pt content plus its vertical padding.
    private let rowHeight: CGFloat = 96

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if viewModel.isLoading {
                // Focusable on purpose. A freshly selected guide renders this
                // before its rows arrive, and a screen with nothing focusable
                // does not merely refuse the incoming focus — tvOS re-resolves
                // focus scope-wide and hands it to the first focusable view it
                // finds, which is the Home button in the nav rail. The rail is
                // focus-driven, so selection follows focus and the viewer is
                // thrown back to Home the instant they pick the guide.
                ProgressView()
                    .padding(.horizontal, 80).padding(.top, 40)
                    .focusable()
                    .focusEffectDisabled()
                    .defaultFocus(in: focusNamespace)
            } else if viewModel.rows.isEmpty {
                // Same reasoning: an empty or failed guide is plain text, and
                // without somewhere for focus to rest it bounces to the rail.
                emptyState
                    .focusable()
                    .focusEffectDisabled()
                    .defaultFocus(in: focusNamespace)
            } else {
                // The jump bar sits above the scrolling strip, not inside it, so
                // Up from the first row reaches it and it never scrolls away.
                jumpBar
                    .padding(.horizontal, 80)
                    // Enough gap that the first row's focus glow does not brush
                    // the chips. Outside the scroll view on purpose: padding
                    // inside it moves the content offset off zero, and then the
                    // first Up scrolls instead of leaving the row.
                    .padding(.bottom, 18)
                strip
            }
            Spacer(minLength: 0)
        }
        .background(SashimiTheme.background)
        .task {
            await viewModel.load()
            // A week of guide is ~600 KB; refetch it every quarter hour, and
            // let a once-a-minute tick redraw what is on and the minutes left.
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
                guard !Task.isCancelled else { break }
                minute = Date()
                ticks += 1
                if ticks % 15 == 0 { await viewModel.load() }
            }
        }
        // Focus that enters while the spinner is up sits on the spinner; when
        // the rows arrive the spinner goes and focus is orphaned — every arrow
        // press then does nothing, which reads as a dead screen. Seen on a
        // real Apple TV. So the first rows to arrive claim focus themselves.
        .onChange(of: viewModel.rows.isEmpty) { wasEmpty, isEmpty in
            guard wasEmpty, !isEmpty, focusedCard == nil,
                  let row = viewModel.rows.first, let entry = row.channel.programs.first else { return }
            DispatchQueue.main.async {
                focusedCard = CardID(row: row.id, entry: entry.id)
            }
        }
        .fullScreenCover(item: $tuned) { tuned in
            PlayerView(item: tuned.item, channelContext: tuned.context)
        }
        .fullScreenCover(isPresented: $showReminders) {
            RemindersListView()
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

    private var strip: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                    channelStrip(row, index: index)
                }
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 80)
        }
        // A focused card grows by 4% and glows 12pt, and a ScrollView clips its
        // content: the first row's ring was sliced flat along the top (seen in
        // a screenshot) while every other row's was drawn whole.
        .scrollClipDisabled()
    }

    /// Now, Tonight, and the next six days at prime time — the way a printed
    /// guide was read. One press answers "what's on Saturday night".
    private var jumpBar: some View {
        let chips = GuideJump.chips(now: minute)
        return HStack(spacing: 10) {
            ForEach(chips) { chip in
                GuideChip(label: chip.label, selected: (jump ?? "Now") == chip.id) {
                    jump = chip.kind == .now ? nil : chip.id
                    turnAllRows(to: chip)
                }
            }
            if !reminders.reminders.isEmpty {
                GuideChip(label: "Reminders · \(reminders.reminders.count)", systemImage: "bell.fill", selected: false) {
                    showReminders = true
                }
            }
            Spacer(minLength: 0)
        }

        // Its own section, so Down from any chip lands in the channels rather
        // than the beam picking a card by geometry across the whole strip.
        .focusSection()
    }

    /// Put the programme airing at the chip's instant first in every row.
    /// Focus stays on the chip; the rows change beneath it.
    private func turnAllRows(to chip: GuideJump) {
        for row in viewModel.rows {
            let programs = row.channel.programs
            offsets[row.id] = chip.kind == .now
                ? 0
                : (programs.firstIndex { $0.endUtc > chip.target } ?? max(0, programs.count - 1))
        }
    }

    private func channelStrip(_ row: GuideRow, index: Int) -> some View {
        let programs = row.channel.programs
        let offset = GuidePaging.clamp(offset: offsets[row.id, default: 0], count: programs.count)
        let visible = GuidePaging.visible(programs, offset: offset)
        let isFirstRow = index == 0

        return HStack(alignment: .center, spacing: 0) {
            channelLabel(row, index: index)
                .frame(width: channelColumnWidth, height: rowHeight, alignment: .leading)

            HStack(spacing: cardGap) {
                // Both page-turn buttons are always in the tree, merely
                // disabled when there is nowhere to go. Inserting one on a
                // turn hands it focus, and a focused button at the far end of
                // the row is exactly where the viewer was not looking.
                PageTurn(systemImage: "chevron.left", width: turnWidth, height: rowHeight,
                         enabled: offset > 0) { turn(row, to: GuidePaging.previous(offset: offset, count: programs.count)) }
                    .id("turn-back-\(row.id)")

                ForEach(Array(visible.enumerated()), id: \.element.id) { slot, entry in
                    GuideBlock(row: row, entry: entry, width: cardWidth, channelNumber: row.channel.number ?? index + 1) {
                        select(row: row, entry: entry)
                    }
                    .focused($focusedCard, equals: CardID(row: row.id, entry: entry.id))
                    // Something has to claim the beam when the screen appears,
                    // or focus stays in the rail and the grid cannot be reached.
                    .defaultFocus(in: isFirstRow && offset == 0 && slot == 0 ? focusNamespace : nil)
                }

                PageTurn(systemImage: "chevron.right", width: turnWidth, height: rowHeight,
                         enabled: GuidePaging.hasMore(programs.count, offset: offset)) { turn(row, to: GuidePaging.next(offset: offset, count: programs.count)) }
                    .id("turn-forward-\(row.id)")

                Spacer(minLength: 0)
            }
        }
        // Each row competes for the focus beam on its own, so up/down moves
        // between channels rather than the whole guide behaving as one target.
        .focusSection()
    }

    /// Turn a row to another offset. Focus stays on the button that was
    /// pressed: moving it onto a card programmatically leaves the focus
    /// engine's own idea of where it is behind, and the next Up or Down then
    /// lands in a slot the viewer did not choose — seen on a real Apple TV.
    private func turn(_ row: GuideRow, to offset: Int) {
        offsets[row.id] = offset
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
                // Numbered in guide order — the same number the player's banner
                // shows and channel up/down steps through.
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(row.channel.number ?? index + 1)")
                        .font(.system(size: 21, weight: .heavy, design: .rounded))
                        .foregroundStyle(Self.railColour(at: index))
                        .monospacedDigit()
                    Text(row.channel.name.uppercased())
                        .font(.system(size: 21, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .lineLimit(1)
                }

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
