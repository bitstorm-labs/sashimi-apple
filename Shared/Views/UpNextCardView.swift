import NukeUI
import SwiftUI

/// What a channel shows between slots: the station, what is up next and when,
/// with a countdown — the TV break, so every programme can start on the half
/// hour. Covers the picture; the previous programme is over and the next has
/// not begun.
struct UpNextCardView: View {
    let card: PlayerViewModel.UpNext

    #if os(tvOS)
    private let scale: CGFloat = 1
    #else
    private let scale: CGFloat = 0.6
    #endif

    /// The apps' shared purple (both themes define the same value).
    private let accent = Color(red: 140 / 255, green: 92 / 255, blue: 199 / 255)

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea()

            VStack(spacing: 22 * scale) {
                HStack(spacing: 18 * scale) {
                    if let number = card.number {
                        Text("\(number)")
                            .font(.system(size: 44 * scale, weight: .heavy, design: .rounded))
                            .foregroundStyle(accent)
                            .monospacedDigit()
                    }
                    if let logo = card.logoURL {
                        LazyImage(url: logo) { state in
                            if let image = state.image {
                                image.resizable().aspectRatio(contentMode: .fit)
                            }
                        }
                        .frame(width: 110 * scale, height: 110 * scale)
                    }
                    Text(card.channelName)
                        .font(.system(size: 40 * scale, weight: .heavy))
                        .tracking(2)
                        .foregroundStyle(.white)
                }

                Text("UP NEXT · \(time(card.startsAt))")
                    .font(.system(size: 24 * scale, weight: .heavy))
                    .tracking(2)
                    .foregroundStyle(accent)
                    .padding(.top, 20 * scale)

                Text(card.title)
                    .font(.system(size: 56 * scale, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let detail = card.detail {
                    Text(detail)
                        .font(.system(size: 28 * scale))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(card.startsAt.timeIntervalSince(context.date).rounded(.up)))
                    Text(String(format: "starts in %d:%02d", left / 60, left % 60))
                        .font(.system(size: 30 * scale, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .monospacedDigit()
                        .padding(.top, 24 * scale)
                }
            }
            .padding(.horizontal, 120 * scale)

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(time(context.date))
                            .font(.system(size: 30 * scale, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                }
            }
            .padding(.horizontal, 80 * scale)
            .padding(.bottom, 60 * scale)
        }
        .transition(.opacity)
    }
}
