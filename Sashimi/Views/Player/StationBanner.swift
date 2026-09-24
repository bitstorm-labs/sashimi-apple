import SwiftUI
import UIKit

/// Only recognises while a station is playing with the transport bar down, so
/// AVKit keeps up and down for everything else.
final class StationStepRecognizer: UIGestureRecognizer {
    var delta = 0
    var shouldStep: () -> Bool = { false }

    // Recognised the moment the press begins. A tap recogniser waits for the
    // release, and AVKit's own recognisers cancelled it before then — the
    // presses arrived, the handler never ran (traced on a real Apple TV).
    // Recognising also cancels the press for AVKit, so a down click flips the
    // channel instead of opening the info panel.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard shouldStep(),
              presses.contains(where: { allowedPressTypes.contains(NSNumber(value: $0.type.rawValue)) }) else {
            state = .failed
            return
        }
        state = .recognized
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        if state == .possible { state = .failed }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        state = .cancelled
    }
}

/// The cable-box info banner shown on tune-in and channel change: number and
/// station, what is on with its episode and a live progress bar, and what is
/// next. Uses the guide's accent and wording so a station reads the same in
/// both places.
struct StationBannerView: View {
    let banner: PlayerViewModel.StationBanner

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline, spacing: 22) {
                if let number = banner.number {
                    Text("\(number)")
                        .font(.system(size: 64, weight: .heavy, design: .rounded))
                        .foregroundStyle(SashimiTheme.accent)
                        .monospacedDigit()
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(banner.channelName.uppercased())
                        .font(.system(size: 30, weight: .heavy))
                        .tracking(1.6)
                        .foregroundStyle(.white)
                    if let description = banner.channelDescription, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                }
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(time(context.date))
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                }
            }

            Rectangle().fill(.white.opacity(0.12)).frame(height: 1)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Text("NOW")
                        .font(.system(size: 18, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(SashimiTheme.accent))
                    Text(banner.title)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let detail = banner.detail {
                        Text(detail)
                            .font(.system(size: 24))
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(1)
                    }
                    if banner.isNew {
                        Text("NEW")
                            .font(.system(size: 18, weight: .heavy))
                            .tracking(1.2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.red.opacity(0.85)))
                    }
                }

                if let start = banner.startsAt, let end = banner.endsAt, end > start {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let total = end.timeIntervalSince(start)
                        let done = min(max(context.date.timeIntervalSince(start), 0), total)
                        let left = Int((end.timeIntervalSince(context.date) / 60).rounded(.up))
                        HStack(spacing: 16) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.18))
                                    Capsule().fill(SashimiTheme.accent)
                                        .frame(width: geo.size.width * done / total)
                                }
                            }
                            .frame(height: 8)
                            Text("\(time(start)) – \(time(end))")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.8))
                                .monospacedDigit()
                                .fixedSize()
                            if left > 0 {
                                Text("\(left) min left")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(SashimiTheme.accent)
                                    .monospacedDigit()
                                    .fixedSize()
                            }
                        }
                    }
                }

                if let next = banner.nextTitle {
                    HStack(spacing: 12) {
                        Text("NEXT")
                            .font(.system(size: 18, weight: .heavy))
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.7))
                        Text(next)
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                        if let at = banner.nextStartsAt {
                            Text("· \(time(at))")
                                .font(.system(size: 22))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        Spacer()
                        Text("▲▼ change channel")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22)
                .fill(.black.opacity(0.78))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08), lineWidth: 1))
        )
    }
}
