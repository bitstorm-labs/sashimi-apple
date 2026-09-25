import NukeUI
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

/// Click and hold on the clickpad while a station plays: a click shows the
/// info banner, a hold opens subtitles and audio. One recogniser tells them
/// apart by duration, because a tap recogniser and a long-press recogniser
/// on the same button each claimed the other's presses under AVKit.
final class StationSelectRecognizer: UIGestureRecognizer {
    enum Kind { case click, hold }

    private(set) var kind: Kind = .click
    var isActive: () -> Bool = { false }
    private var holdTimer: DispatchWorkItem?

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        guard isActive(), presses.contains(where: { $0.type == .select }) else {
            state = .failed
            return
        }
        state = .began
        let timer = DispatchWorkItem { [weak self] in
            guard let self, self.state == .began || self.state == .changed else { return }
            self.kind = .hold
            self.state = .ended
        }
        holdTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: timer)
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        holdTimer?.cancel()
        guard state == .began || state == .changed else { return }
        kind = .click
        state = .ended
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent) {
        holdTimer?.cancel()
        state = .cancelled
    }

    override func reset() {
        holdTimer?.cancel()
        holdTimer = nil
        kind = .click
        super.reset()
    }
}

/// The channel's info bar: the bottom-edge mirror of the player's top bar —
/// full width, the same translucent black, the same 80pt margins. Logo, number
/// and station; what is on with a live progress bar; what is next; and how the
/// remote drives a channel, since none of the usual controls are there.
struct StationBannerView: View {
    let banner: PlayerViewModel.StationBanner

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 24) {
                if let number = banner.number {
                    Text("\(number)")
                        .font(.system(size: 60, weight: .heavy, design: .rounded))
                        .foregroundStyle(SashimiTheme.accent)
                        .monospacedDigit()
                }
                if let logo = banner.logoURL {
                    LazyImage(url: logo) { state in
                        if let image = state.image {
                            image.resizable().aspectRatio(contentMode: .fit)
                        }
                    }
                    .id(logo)
                    .frame(width: 96, height: 96)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(banner.channelName.uppercased())
                        .font(.system(size: 34, weight: .heavy))
                        .tracking(1.6)
                        .foregroundStyle(.white)
                    if let description = banner.channelDescription, !description.isEmpty {
                        Text(description)
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(time(context.date))
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(.white)
                            .monospacedDigit()
                    }
                    if banner.isPaused {
                        Label("PAUSED", systemImage: "pause.fill")
                            .font(.system(size: 20, weight: .heavy))
                            .foregroundStyle(SashimiTheme.accent)
                    } else if banner.minutesBehindLive > 0 {
                        Text("\(banner.minutesBehindLive) min behind live")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
            }

            HStack(spacing: 12) {
                Text("NOW")
                    .font(.system(size: 18, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(SashimiTheme.accent))
                Text(banner.title)
                    .font(.system(size: 32, weight: .bold))
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
                                Capsule().fill(.white.opacity(0.25))
                                Capsule().fill(SashimiTheme.accent)
                                    .frame(width: geo.size.width * done / total)
                            }
                        }
                        .frame(height: 6)
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

            HStack(spacing: 12) {
                if let next = banner.nextTitle {
                    Text("NEXT")
                        .font(.system(size: 18, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.7))
                    if let at = banner.nextStartsAt {
                        Text(time(at))
                            .font(.system(size: 22))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    Text(next)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                Spacer()
                Text("▲▼ channels     ◀▶ guide     click  info     hold  subtitles & audio")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 28)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(0.4))
    }
}

/// The station's mark, faint in the corner while a channel plays, the way
/// broadcast TV marks its picture: logo over name. Only while the bar is down.
struct StationMarkView: View {
    let mark: PlayerViewModel.StationMark

    var body: some View {
        VStack {
            HStack {
                // Stacked — logo over name — on one centred column.
                VStack(spacing: 6) {
                    if let logo = mark.logoURL {
                        LazyImage(url: logo) { state in
                            if let image = state.image {
                                image.resizable().aspectRatio(contentMode: .fit)
                            }
                        }
                        // A new identity per station: the image view otherwise
                        // kept the previous station's logo after a flip.
                        .id(logo)
                        .frame(width: 72, height: 72)
                    }
                    Text(mark.name)
                        .font(.system(size: 16, weight: .heavy))
                        .tracking(1.2)
                }
                .foregroundStyle(.white)
                Spacer()
            }
            .opacity(0.45)
            Spacer()
        }
        // Measured from the screen edge, not the overscan safe area (~80pt
        // sides, ~60pt top), so it can sit tight in the corner.
        .padding(.leading, 64)
        .padding(.top, 47)
        .ignoresSafeArea()
    }
}
