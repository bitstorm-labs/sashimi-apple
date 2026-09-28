import SwiftUI

/// One programme in the guide, as a fixed-width card.
struct GuideBlock: View {
    let row: GuideRow
    let entry: GuideEntry
    let width: CGFloat
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool
    @ObservedObject private var reminders = StationReminders.shared

    private var isNow: Bool { entry.isAiring(at: Date()) }

    private var hasReminder: Bool {
        reminders.isSet(channelID: row.channel.id, startsAt: entry.startUtc)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if isNow {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                    }
                    Text(row.title(for: entry))
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(SashimiTheme.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if entry.isNew {
                        Text("NEW")
                            .font(.system(size: 13, weight: .heavy))
                            .tracking(0.8)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                    if hasReminder {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(SashimiTheme.accent)
                    }
                }

                if let subtitle = row.subtitle(for: entry) {
                    Text(subtitle)
                        .font(.system(size: 17))
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .lineLimit(1)
                }

                // The card says when it is, not which column it sits in: pages
                // are turned per row, so "Now / Next / Later" would only be
                // true on a row's first page.
                Text(isNow ? "Now · \(remaining) left" : startLabel)
                    .font(.system(size: 16, weight: isNow ? .semibold : .regular))
                    .foregroundStyle(isNow ? SashimiTheme.accent : SashimiTheme.textTertiary)
                    .lineLimit(1)
            }
            .frame(width: width, height: 72, alignment: .topLeading)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    // What is on now reads as filled; everything later is a
                    // quieter surface, so the eye lands on the present first.
                    .fill(isNow ? SashimiTheme.accent.opacity(0.28) : SashimiTheme.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isFocused ? SashimiTheme.focus : .white.opacity(0.08),
                            lineWidth: isFocused ? 4 : 1)
            )
            // Nothing above this view clips, so the glow and scale are drawn
            // whole. The previous grid clipped its timeline and sliced them.
            .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        // Long press on anything still to come: "Remind me". What is on now
        // needs no reminder — selecting it tunes in.
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
        .accessibilityLabel(accessibility)
    }

    /// "13:55" today; "Sat 18:00" for any other day, because a week of guide
    /// makes a bare time ambiguous.
    private var startLabel: String {
        if Calendar.current.isDateInToday(entry.startUtc) {
            return ClockTime.time(entry.startUtc)
        }
        return ClockTime.weekdayTime(entry.startUtc)
    }

    private var remaining: String {
        let minutes = max(1, Int((entry.endUtc.timeIntervalSince(Date()) / 60).rounded(.up)))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }

    private var accessibility: String {
        let time = ClockTime.time(entry.startUtc)
        let when = isNow ? "now airing, \(remaining) left" : "at \(time)"
        return "\(row.channel.name), \(row.title(for: entry)), \(when)"
    }
}

/// What a future programme is, for when the viewer asks about one they cannot
/// yet watch.
struct GuideDetailView: View {
    let row: GuideRow
    let entry: GuideEntry

    @Environment(\.dismiss) private var dismiss

    private var item: BaseItemDto? { row.items[entry.itemId] }

    var body: some View {
        ZStack {
            SashimiTheme.background.ignoresSafeArea()

            VStack(alignment: .leading, spacing: 20) {
                Text(row.channel.name.uppercased())
                    .font(.system(size: 20, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(SashimiTheme.accent)

                Text(row.title(for: entry))
                    .font(.system(size: 48, weight: .bold))
                    .foregroundStyle(SashimiTheme.textPrimary)

                Text(timing)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(SashimiTheme.textSecondary)

                if let overview = item?.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.system(size: 22))
                        .foregroundStyle(SashimiTheme.textSecondary.opacity(0.9))
                        .lineLimit(6)
                        .frame(maxWidth: 1100, alignment: .leading)
                }

                Text("Airs later — tune in when it starts.")
                    .font(.system(size: 19))
                    .foregroundStyle(SashimiTheme.textTertiary)

                Button("Close") { dismiss() }
                    .padding(.top, 20)
            }
            .padding(80)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var timing: String {
        let start = ClockTime.time(entry.startUtc)
        let end = ClockTime.time(entry.endUtc)
        var parts = ["\(start) – \(end)"]
        if let subtitle = row.subtitle(for: entry) { parts.append(subtitle) }
        if let certificate = item?.officialRating { parts.append(certificate) }
        if let rating = item?.communityRating { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: " · ")
    }
}

/// The button at either end of a row's strip. Turning happens on a press,
/// never on focus: a focus-triggered turn restructured the row, the button
/// that appeared took focus, and the page turned straight back. Disabled
/// rather than absent when there is nowhere to go, for the same reason —
/// the row's structure must not change under the viewer.
struct PageTurn: View {
    let systemImage: String
    let width: CGFloat
    let height: CGFloat
    let enabled: Bool
    let turn: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: turn) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(isFocused ? SashimiTheme.textPrimary : SashimiTheme.textTertiary)
                .frame(width: width, height: height)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(SashimiTheme.cardBackground.opacity(isFocused ? 1 : 0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isFocused ? SashimiTheme.focus : .clear, lineWidth: 4)
                )
                .opacity(enabled ? 1 : 0.25)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .disabled(!enabled)
        .focused($isFocused)
    }
}
