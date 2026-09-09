import SwiftUI
import AVKit

struct MobilePlayerLoadingView: View {
    @ObservedObject var viewModel: PlayerViewModel
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .padding(20)

            VStack(spacing: 16) {
                if viewModel.isLoading {
                    ProgressView().scaleEffect(1.5)
                    Text("Loading...").foregroundStyle(.white)
                } else if let errorMessage = viewModel.errorMessage {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    Text(errorMessage)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .padding()
                    Button("Dismiss", action: onClose)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea()
    }
}

/// Owns the complete transport row when episode navigation is opted in.
/// AVPlayer has no public insertion point on iOS, so using one app-owned row
/// keeps the ordering and spacing identical on iPhone, iPad, and tvOS.
struct MobileEpisodeTransportControls: View {
    let state: PlayerTransitionState
    let player: AVPlayer?
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onSkipBackward: () -> Void
    let onPlayPause: () -> Void
    let onSkipForward: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { _ in
            HStack(spacing: 18) {
                MobileEpisodeNavigationButton(
                    title: "Previous Episode",
                    systemImage: "backward.fill",
                    isEnabled: state.canPlayPrevious,
                    action: onPrevious
                )
                MobileEpisodeNavigationButton(
                    title: "Skip Backward 10 Seconds",
                    systemImage: "gobackward.10",
                    isEnabled: player != nil,
                    action: onSkipBackward
                )
                MobileEpisodeNavigationButton(
                    title: player?.timeControlStatus == .playing ? "Pause" : "Play",
                    systemImage: player?.timeControlStatus == .playing ? "pause.fill" : "play.fill",
                    isEnabled: player != nil,
                    action: onPlayPause,
                    isPrimary: true
                )
                MobileEpisodeNavigationButton(
                    title: "Skip Forward 10 Seconds",
                    systemImage: "goforward.10",
                    isEnabled: player != nil,
                    action: onSkipForward
                )
                MobileEpisodeNavigationButton(
                    title: "Next Episode",
                    systemImage: "forward.fill",
                    isEnabled: state.canPlayNext,
                    action: onNext
                )
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 18)
        .padding(.bottom, 54)
        .allowsHitTesting(true)
        .ignoresSafeArea()
    }
}

private struct MobileEpisodeNavigationButton: View {
    let title: String
    let systemImage: String
    let isEnabled: Bool
    let action: () -> Void
    var isPrimary = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: isPrimary ? 26 : 20, weight: .semibold))
                .frame(width: isPrimary ? 64 : 52, height: isPrimary ? 64 : 52)
        }
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .foregroundStyle(.white)
        .background(Color.white.opacity(0.18), in: Circle())
        .contentShape(Circle())
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
    }
}

struct MobilePlayerEndCard: View {
    let state: PlayerTransitionState
    let item: BaseItemDto
    let streamInfo: PlayerViewModel.StreamInfo?
    let onPlayNext: () -> Void
    let onReplay: () -> Void
    let onDone: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.92).ignoresSafeArea()
            VStack(spacing: 18) {
                Text(title)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                if let metadataText {
                    Text(metadataText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.55))
                }
                HStack(spacing: 12) {
                    if state.canPlayNext {
                        Button("Play Next", action: onPlayNext)
                            .accessibilityLabel("Play Next Episode")
                    }
                    Button("Replay", action: onReplay)
                        .disabled(state.isTransitioning)
                    Button("Done", action: onDone)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(32)
            .frame(maxWidth: 520)
        }
    }

    private var title: String {
        switch state.endCard {
        case .nextEpisode, .lookupFailed: return "Episode Complete"
        case .finalEpisode: return "Series Complete"
        case nil: return "Playback Complete"
        }
    }

    private var message: String {
        switch state.endCard {
        case .nextEpisode: return "Ready for the next episode."
        case .finalEpisode: return "There are no more episodes available."
        case .lookupFailed: return "The next episode could not be loaded. Try again later or replay this episode."
        case nil: return ""
        }
    }

    private var metadataText: String? {
        var parts: [String] = []
        if let year = item.displayYear {
            parts.append(String(year))
        }
        if let ticks = item.runTimeTicks {
            let minutes = Int(Double(ticks) / 10_000_000.0 / 60.0)
            if minutes > 0 {
                parts.append("\(minutes) min")
            }
        }
        if let streamInfo {
            parts.append(streamInfo.label)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
