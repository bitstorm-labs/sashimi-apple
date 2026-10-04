import SwiftUI

// The row of a download in flight: bar, percent, bytes, speed and time left.
// The wording and the numbers come from DownloadProgressModel.swift.

struct ActiveDownloadRow: View {
    let item: DownloadedItem
    let isPreparing: Bool
    /// Bytes, total, speed and time left; nil while the download is queued.
    let detail: DownloadProgressDetail?
    /// Set while downloads can't use the current network (offline, or
    /// cellular with "Download over Cellular" off): the row says so instead
    /// of looking stuck.
    var waitReason: DownloadWaitReason?
    let onCancel: () -> Void

    @Environment(\.horizontalSizeClass) private var sizeClass

    private var rowStatus: DownloadRowStatus {
        DownloadRowStatus.resolve(waitReason: waitReason, isPreparing: isPreparing, detail: detail)
    }

    var body: some View {
        HStack(spacing: MobileSpacing.md) {
            DownloadPoster(item: item)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(1)

                if let seriesName = item.seriesName {
                    Text(seriesName)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                }

                status
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(MobileColors.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel \(item.displayTitle)")
        }
        .padding(MobileSpacing.md)
    }

    /// "S3:E5 · Hakeldama" for an episode (its show is the line below).
    private var title: String {
        guard item.seriesName != nil, let season = item.seasonNumber, let episode = item.episodeNumber else {
            return item.name
        }
        return "S\(season):E\(episode) · \(item.name)"
    }

    @ViewBuilder
    private var status: some View {
        switch rowStatus {
        case .waiting(let reason):
            // Keep what has arrived on show; the label replaces speed and time.
            barAndText(fraction: detail?.display.fraction, dimmed: true) {
                HStack(spacing: 6) {
                    Image(systemName: reason == .offline ? "wifi.slash" : "wifi")
                    Text(reason.activeLabel)
                }
                .font(.system(size: 12))
                .foregroundStyle(MobileColors.textSecondary)
                .lineLimit(1)
            }
        case .preparing:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.6)
                Text("Preparing...")
                    .font(.system(size: 12))
                    .foregroundStyle(MobileColors.textSecondary)
            }
        case .downloading(let detail):
            if detail.display.fraction == nil {
                // No length and nothing to estimate from: bytes and speed only.
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    DownloadStatusText(detail: detail)
                }
            } else {
                barAndText(fraction: detail.display.fraction, dimmed: false) {
                    DownloadStatusText(detail: detail)
                }
            }
        case .queued:
            Text("Queued")
                .font(.system(size: 12))
                .foregroundStyle(MobileColors.textTertiary)
        }
    }

    /// The bar with its text beside it where there is room (iPad), under it
    /// where there isn't (iPhone, Split View).
    @ViewBuilder
    private func barAndText(fraction: Double?, dimmed: Bool, @ViewBuilder text: () -> some View) -> some View {
        if let fraction {
            if sizeClass == .compact {
                VStack(alignment: .leading, spacing: 5) {
                    DownloadProgressBar(fraction: fraction, dimmed: dimmed)
                    text()
                }
            } else {
                HStack(spacing: 10) {
                    DownloadProgressBar(fraction: fraction, dimmed: dimmed)
                        .frame(width: 180)
                    text()
                }
            }
        } else {
            text()
        }
    }

    private var accessibilityText: String {
        let name = item.displayTitle == item.name ? item.name : "\(item.displayTitle), \(item.name)"
        switch rowStatus {
        case .waiting(let reason):
            guard let fraction = detail?.display.fraction else { return "\(name), \(reason.activeLabel)" }
            let percent = DownloadProgressText.percent(fraction).replacingOccurrences(of: "%", with: " percent")
            return "\(name), \(reason.activeLabel), \(percent)"
        case .preparing:
            return "\(name), preparing"
        case .downloading(let detail):
            return "\(name), downloading, \(DownloadProgressText.accessibilityLabel(for: detail))"
        case .queued:
            return "\(name), queued"
        }
    }
}

/// Thin determinate bar in the accent colour.
struct DownloadProgressBar: View {
    let fraction: Double
    var dimmed = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(MobileColors.progressBackground)
                Capsule()
                    .fill(MobileColors.accent.opacity(dimmed ? 0.5 : 1))
                    .frame(width: max(geo.size.width * CGFloat(min(max(fraction, 0), 1)), 5))
                    .animation(.linear(duration: 0.5), value: fraction)
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

/// "43% · 182 MB of ~420 MB · 3.1 MB/s · about 1 min left", or as much of it
/// as the width allows (see DownloadProgressText.statusLines).
struct DownloadStatusText: View {
    let detail: DownloadProgressDetail

    var body: some View {
        let lines = DownloadProgressText.statusLines(for: detail)
        ViewThatFits(in: .horizontal) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                text(for: line)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private func text(for line: DownloadStatusLine) -> Text {
        let rest = Text(line.parts.joined(separator: " · "))
            .foregroundColor(MobileColors.textSecondary)
        guard let percent = line.percent else {
            return rest.font(.system(size: 12)).monospacedDigit()
        }
        let lead = Text(percent)
            .fontWeight(.semibold)
            .foregroundColor(MobileColors.textPrimary)
        let joined = line.parts.isEmpty
            ? lead
            : lead + Text(" · ").foregroundColor(MobileColors.textTertiary) + rest
        return joined.font(.system(size: 12)).monospacedDigit()
    }
}
