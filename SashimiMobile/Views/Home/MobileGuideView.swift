import SwiftUI

/// The SashimiTV guide on iPad: channels down, time across.
///
/// The tvOS guide has to fit three hours on screen without scrolling sideways,
/// because roaming a grid with a remote is miserable. Touch has no such
/// problem, so this one scrolls in both directions and can afford honest
/// proportions — a 22-minute sitcom really is a third the width of a film.
struct MobileGuideView: View {
    @StateObject private var viewModel = GuideViewModel(hours: 168)
    @State private var tuned: TunedChannel?
    @State private var selected: GuideSelection?

    /// The day on screen. A week is fetched, but a week drawn at honest
    /// proportions is ~60,000pt of row per channel; a chip picks one day
    /// (from now, for Now and Tonight) and the grid scrolls within it.
    @State private var windowStart = Date()
    @State private var windowHours: Double = 24
    @State private var jump = "Now"
    /// Where the timeline scrolls to after a jump: 18:00 for a day, now for Now.
    @State private var scrollTarget: Date?
    @State private var minute = Date()
    @State private var showReminders = false
    @ObservedObject private var reminders = StationReminders.shared

    /// Wide enough that a half-hour programme can show a title.
    private let pointsPerMinute: CGFloat = 6
    private let channelColumnWidth: CGFloat = 220
    private let rowHeight: CGFloat = 96

    private var windowEnd: Date { windowStart.addingTimeInterval(windowHours * 3600) }
    private var totalWidth: CGFloat { CGFloat(windowHours * 60) * pointsPerMinute }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if viewModel.isLoading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else if viewModel.rows.isEmpty {
                emptyState
            } else {
                dayChips
                grid
            }
            Spacer(minLength: 0)
        }
        .background(MobileColors.background)
        .task {
            await viewModel.load()
            // A week is ~600 KB: refetch every quarter hour, and tick every
            // minute so the now-line and highlight stay honest. Only "Now"
            // follows the clock; a picked day stays put.
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * NSEC_PER_SEC)
                guard !Task.isCancelled else { break }
                minute = Date()
                if jump == "Now" { windowStart = minute }
                ticks += 1
                if ticks % 15 == 0 { await viewModel.load() }
            }
        }
        .fullScreenCover(item: $tuned) { tuned in
            MobilePlayerView(item: tuned.item, channelContext: tuned.context)
        }
        .sheet(isPresented: $showReminders) { MobileRemindersList() }
        .sheet(item: $selected) { selection in
            MobileGuideDetailSheet(row: selection.row, entry: selection.entry)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Guide")
                .font(.largeTitle.bold())
                .foregroundStyle(MobileColors.textPrimary)
            Spacer()
            if !reminders.reminders.isEmpty {
                Button { showReminders = true } label: {
                    Label("\(reminders.reminders.count)", systemImage: "bell.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .tint(MobileColors.accent)
                .accessibilityLabel("Reminders")
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(context.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundStyle(MobileColors.textSecondary)
            }
        }
        .padding(.horizontal, MobileSpacing.md)
        .padding(.top, MobileSpacing.md)
        .padding(.bottom, MobileSpacing.sm)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            viewModel.loadFailed ? "Couldn't reach the server" : "No channels yet",
            systemImage: "antenna.radiowaves.left.and.right",
            description: Text(viewModel.loadFailed
                ? "The guide needs the server to be reachable."
                : "Channels are created in Jellyfin under Dashboard → Plugins → Channels.")
        )
        .frame(maxWidth: .infinity, minHeight: 240)
    }

    /// Now, Tonight, and the next six days — the same chips as tvOS and Roku.
    private var dayChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GuideJump.chips(now: minute)) { chip in
                    let picked = jump == chip.label
                    Button { pick(chip) } label: {
                        Text(chip.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(picked ? Color.black : MobileColors.textPrimary)
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(Capsule().fill(picked ? MobileColors.accent : MobileColors.cardBackground))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, MobileSpacing.md)
        }
        .padding(.bottom, MobileSpacing.sm)
    }

    private func pick(_ chip: GuideJump) {
        jump = chip.label
        let calendar = Calendar.current
        switch chip.kind {
        case .now:
            windowStart = Date()
            scrollTarget = nil
        case .tonight:
            windowStart = Date()
            scrollTarget = chip.target
        case .day:
            windowStart = calendar.startOfDay(for: chip.target)
            scrollTarget = chip.target
        }
        windowHours = 24
    }

    private var grid: some View {
        ScrollView(.vertical, showsIndicators: false) {
            HStack(alignment: .top, spacing: 0) {
                // Channel names sit outside the scrolling timeline so they stay
                // put while the schedule moves.
                VStack(alignment: .leading, spacing: 10) {
                    // Width is mandatory: Color.clear is greedy, and without it
                    // this spacer takes the whole row and shoves the timeline off.
                    Color.clear.frame(width: channelColumnWidth, height: 28)
                    ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, row in
                        channelLabel(row, index: index)
                            .frame(width: channelColumnWidth, height: rowHeight, alignment: .leading)
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            timeRuler
                            ForEach(viewModel.rows) { row in
                                channelRow(row)
                            }
                        }
                        // Overlay rather than a ZStack sibling: a bare Rectangle in
                        // a ZStack has no intrinsic height and stretches the stack.
                        .overlay(alignment: .topLeading) { nowLine }
                    }
                    .onChange(of: jump) { _, _ in scroll(proxy) }
                    .onAppear { scroll(proxy) }
                }
            }
            .padding(.horizontal, MobileSpacing.md)
            .padding(.bottom, MobileSpacing.xl)
        }
    }

    /// Name over its description, against a colour rail — the same treatment as
    /// tvOS, so the two screens describe a channel the same way.
    private func channelLabel(_ row: GuideRow, index: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Self.railColour(at: index))
                .frame(width: 3)
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 3) {
                // The logo travels with the name, on its line.
                HStack(alignment: .center, spacing: 6) {
                    if row.channel.logo != nil {
                        ChannelLogoView(channelId: row.channel.id, logo: row.channel.logo, size: 18)
                    }
                    Text(row.channel.name.uppercased())
                        .font(.caption.bold())
                        .tracking(0.8)
                        .foregroundStyle(MobileColors.textPrimary)
                        .lineLimit(1)
                }

                if let description = row.channel.description, !description.isEmpty {
                    Text(description)
                        .font(.caption2)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(3)
                        // Without this a wrapped string is given one line's
                        // height and clipped, because the row height is fixed.
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.trailing, MobileSpacing.sm)
    }

    /// Half-hour ticks laid out in an HStack rather than offset: offset views
    /// keep their original frame, and scrollTo needs a real one to land on.
    private var timeRuler: some View {
        let firstTick = windowStart.nextGuideHalfHour
        let ticks = stride(from: 0, to: Int(windowHours * 2), by: 1).map {
            firstTick.addingTimeInterval(Double($0) * 1800)
        }
        return HStack(spacing: 0) {
            Color.clear.frame(width: max(0, offset(for: firstTick)), height: 28)
                .id(Self.timelineStart)
            ForEach(ticks, id: \.timeIntervalSince1970) { tick in
                Text(tick.formatted(date: .omitted, time: .shortened))
                    .font(.caption2)
                    .foregroundStyle(MobileColors.textTertiary)
                    .frame(width: 30 * pointsPerMinute, height: 28, alignment: .leading)
                    .id(tick.timeIntervalSince1970)
            }
        }
        .frame(width: totalWidth, height: 28, alignment: .topLeading)
    }

    /// Scroll id of the leading edge; ticks use their epoch, which is never negative.
    private static let timelineStart: TimeInterval = -1

    private func scroll(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget else {
            // The very start of the timeline, not the next half-hour tick:
            // scrolling to the tick hid the minutes before it and sliced the
            // programmes on air now in half (seen in a screenshot).
            proxy.scrollTo(Self.timelineStart, anchor: .leading)
            return
        }
        // The tick at or just before the target, so 18:00 lands at the left.
        let tick = Date(timeIntervalSince1970: (target.timeIntervalSince1970 / 1800).rounded(.down) * 1800)
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(tick.timeIntervalSince1970, anchor: .leading)
        }
    }

    private func channelRow(_ row: GuideRow) -> some View {
        HStack(spacing: 4) {
            // Only the day on screen. The row lays blocks end to end, so a
            // programme outside the window would still take up space.
            ForEach(row.channel.programs.filter { $0.endUtc > windowStart && $0.startUtc < windowEnd }) { entry in
                MobileGuideBlock(
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
                .fill(MobileColors.accent)
                .frame(width: 2, height: gridHeight)
                .offset(x: offset(for: context.date))
                .opacity(context.date >= windowStart ? 1 : 0)
        }
        .allowsHitTesting(false)
    }

    /// Explicit because the line is an overlay: ruler, then a row and its gap
    /// for each channel.
    private var gridHeight: CGFloat {
        28 + CGFloat(viewModel.rows.count) * (rowHeight + 10)
    }

    // MARK: - Geometry

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
        return max(44, CGFloat(minutes) * pointsPerMinute - 4)
    }

    // MARK: - Palette

    /// Cycled by row so the palette reads as an index down the screen and
    /// neighbouring channels never share a colour. No purple: that is the
    /// accent the grid uses for what is on now.
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

/// One programme in the guide.
struct MobileGuideBlock: View {
    let row: GuideRow
    let entry: GuideEntry
    let width: CGFloat
    let onSelect: () -> Void

    @ObservedObject private var reminders = StationReminders.shared

    private var isNow: Bool { entry.isAiring(at: Date()) }

    private var hasReminder: Bool {
        reminders.isSet(channelID: row.channel.id, startsAt: entry.startUtc)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if isNow {
                        Circle().fill(Color.red).frame(width: 5, height: 5)
                    }
                    Text(row.title(for: entry))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(MobileColors.textPrimary)
                        .lineLimit(1)
                    if entry.isNew {
                        Text("NEW")
                            .font(.system(size: 9, weight: .heavy))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                    if hasReminder {
                        Image(systemName: "bell.fill")
                            .font(.caption2)
                            .foregroundStyle(MobileColors.accent)
                    }
                }

                if let subtitle = row.subtitle(for: entry) {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                }

                Text(Calendar.current.isDateInToday(entry.startUtc)
                     ? entry.startUtc.formatted(date: .omitted, time: .shortened)
                     : entry.startUtc.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(.caption2)
                    .foregroundStyle(MobileColors.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: width, height: rowContentHeight, alignment: .topLeading)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    // What is on now reads as filled; everything later is a
                    // quieter surface, so the eye lands on the present first.
                    .fill(isNow ? MobileColors.accent.opacity(0.28) : MobileColors.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !isNow && entry.startUtc > Date() {
                Button {
                    reminders.toggle(.init(
                        channelID: row.channel.id,
                        channelName: row.channel.name,
                        title: row.title(for: entry),
                        startsAt: entry.startUtc
                    ))
                } label: {
                    Label(hasReminder ? "Cancel Reminder" : "Remind Me",
                          systemImage: hasReminder ? "bell.slash" : "bell")
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.channel.name), \(row.title(for: entry)), "
            + (isNow ? "now airing" : "at \(entry.startUtc.formatted(date: .omitted, time: .shortened))"))
    }

    private var rowContentHeight: CGFloat { 64 }
}

/// What a future programme is, for when the viewer asks about one they cannot
/// yet watch.
struct MobileGuideDetailSheet: View {
    let row: GuideRow
    let entry: GuideEntry

    @Environment(\.dismiss) private var dismiss

    private var item: BaseItemDto? { row.items[entry.itemId] }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                    Text(row.channel.name.uppercased())
                        .font(.caption.bold())
                        .tracking(1)
                        .foregroundStyle(MobileColors.accent)

                    Text(row.title(for: entry))
                        .font(.title.bold())
                        .foregroundStyle(MobileColors.textPrimary)

                    Text(timing)
                        .font(.subheadline)
                        .foregroundStyle(MobileColors.textSecondary)

                    if let overview = item?.overview, !overview.isEmpty {
                        Text(overview)
                            .font(.body)
                            .foregroundStyle(MobileColors.textSecondary)
                            .padding(.top, MobileSpacing.xs)
                    }

                    Text("Airs later — tune in when it starts.")
                        .font(.footnote)
                        .foregroundStyle(MobileColors.textTertiary)
                        .padding(.top, MobileSpacing.xs)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(MobileSpacing.md)
            }
            .background(MobileColors.background)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var timing: String {
        let start = entry.startUtc.formatted(date: .omitted, time: .shortened)
        let end = entry.endUtc.formatted(date: .omitted, time: .shortened)
        var parts = ["\(start) – \(end)"]
        if let subtitle = row.subtitle(for: entry) { parts.append(subtitle) }
        if let certificate = item?.officialRating { parts.append(certificate) }
        if let rating = item?.communityRating { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: " · ")
    }
}

private extension Date {
    /// The next :00 or :30 at or after this instant, so the ruler reads in
    /// round numbers rather than starting at whatever minute it happens to be.
    var nextGuideHalfHour: Date {
        let interval: TimeInterval = 1800
        return Date(timeIntervalSince1970: (timeIntervalSince1970 / interval).rounded(.up) * interval)
    }
}
