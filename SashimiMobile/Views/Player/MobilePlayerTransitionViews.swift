import SwiftUI

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

struct MobileEpisodeNavigationControls: View {
    let state: PlayerTransitionState
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onPrevious) {
                Label("Previous Episode", systemImage: "backward.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(!state.canPlayPrevious)
            .accessibilityLabel("Previous Episode")

            Button(action: onNext) {
                Label("Next Episode", systemImage: "forward.fill")
                    .labelStyle(.iconOnly)
            }
            .disabled(!state.canPlayNext)
            .accessibilityLabel("Next Episode")
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .buttonStyle(.bordered)
        .tint(.white.opacity(0.8))
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
