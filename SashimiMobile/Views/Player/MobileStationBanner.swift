import SwiftUI

/// The station info banner at phone/tablet size — the station, what is on
/// with a live progress bar, and what is next. Same content as tvOS.
struct MobileStationBannerView: View {
    let banner: PlayerViewModel.StationBanner

    private func time(_ date: Date) -> String { ClockTime.time(date) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(banner.channelName.uppercased())
                        .font(.subheadline.weight(.heavy))
                        .tracking(1)
                        .foregroundStyle(.white)
                    if let description = banner.channelDescription, !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            HStack(spacing: 8) {
                Text("NOW")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(MobileColors.accent))
                Text(banner.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if banner.isNew {
                    Text("NEW")
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.85)))
                }
            }
            if let detail = banner.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }

            if let start = banner.startsAt, let end = banner.endsAt, end > start {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let total = end.timeIntervalSince(start)
                    let done = min(max(context.date.timeIntervalSince(start), 0), total)
                    let left = Int((end.timeIntervalSince(context.date) / 60).rounded(.up))
                    HStack(spacing: 10) {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.2))
                                Capsule().fill(MobileColors.accent).frame(width: geo.size.width * done / total)
                            }
                        }
                        .frame(height: 5)
                        Text("\(time(start)) – \(time(end))\(left > 0 ? " · \(left) min left" : "")")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.white.opacity(0.8))
                            .fixedSize()
                    }
                }
            }

            if let next = banner.nextTitle {
                HStack(spacing: 6) {
                    Text("NEXT").font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.6))
                    Text(next).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                    if let at = banner.nextStartsAt {
                        Text("· \(time(at))").font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 640, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.78)))
    }
}

/// Channel up/down for touch: a vertical pill on the right edge while a
/// station plays and the controls are showing.
struct MobileChannelStepper: View {
    let onUp: () -> Void
    let onDown: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onUp) {
                Image(systemName: "chevron.up").frame(width: 52, height: 52)
            }
            .accessibilityLabel("Channel up")
            Text("CH").font(.caption2.weight(.heavy)).foregroundStyle(.white.opacity(0.7))
            Button(action: onDown) {
                Image(systemName: "chevron.down").frame(width: 52, height: 52)
            }
            .accessibilityLabel("Channel down")
        }
        .font(.title3.weight(.bold))
        .foregroundStyle(.white)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.55)))
    }
}
