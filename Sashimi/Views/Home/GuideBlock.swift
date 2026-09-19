import SwiftUI

/// One programme in the guide.
struct GuideBlock: View {
    let row: GuideRow
    let entry: GuideEntry
    let width: CGFloat
    let onSelect: () -> Void

    @FocusState private var isFocused: Bool

    private var isNow: Bool { entry.isAiring(at: Date()) }

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
                }

                if let subtitle = row.subtitle(for: entry) {
                    Text(subtitle)
                        .font(.system(size: 17))
                        .foregroundStyle(SashimiTheme.textSecondary)
                        .lineLimit(1)
                }

                Text(entry.startUtc.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 16))
                    .foregroundStyle(SashimiTheme.textTertiary)
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
            .shadow(color: isFocused ? SashimiTheme.focusGlow : .clear, radius: 12)
            .scaleEffect(isFocused ? 1.04 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: isFocused)
        }
        .buttonStyle(PlainNoHighlightButtonStyle())
        .focused($isFocused)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibility)
    }

    private var accessibility: String {
        let time = entry.startUtc.formatted(date: .omitted, time: .shortened)
        let when = isNow ? "now airing" : "at \(time)"
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
        let start = entry.startUtc.formatted(date: .omitted, time: .shortened)
        let end = entry.endUtc.formatted(date: .omitted, time: .shortened)
        var parts = ["\(start) – \(end)"]
        if let subtitle = row.subtitle(for: entry) { parts.append(subtitle) }
        if let certificate = item?.officialRating { parts.append(certificate) }
        if let rating = item?.communityRating { parts.append(String(format: "★ %.1f", rating)) }
        return parts.joined(separator: " · ")
    }
}
