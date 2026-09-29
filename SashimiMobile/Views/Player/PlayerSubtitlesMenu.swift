import SwiftUI

/// A dedicated captions button beside the gear. Subtitles used to live only at
/// the bottom of the gear menu, under Quality, Audio and Speed, and a viewer
/// looking for them did not find them (iPad feedback). tvOS has the same
/// captions.bubble control in its transport bar. Filled while subtitles are on.
struct PlayerSubtitlesMenu: View {
    @ObservedObject var viewModel: PlayerViewModel

    private var tracks: [SubtitleTrackOption] {
        viewModel.subtitleTracks.filter { !$0.isOffOption }
    }

    private var subtitlesOn: Bool {
        guard let id = viewModel.selectedSubtitleTrackId else { return false }
        return id != "off"
    }

    var body: some View {
        if !tracks.isEmpty {
            Menu {
                Button {
                    viewModel.disableSubtitles()
                } label: {
                    if subtitlesOn {
                        Text("Off")
                    } else {
                        Label("Off", systemImage: "checkmark")
                    }
                }
                ForEach(tracks) { track in
                    Button {
                        viewModel.selectSubtitleTrack(track)
                    } label: {
                        if viewModel.selectedSubtitleTrackId == track.id {
                            Label(track.displayName, systemImage: "checkmark")
                        } else {
                            Text(track.displayName)
                        }
                    }
                }
            } label: {
                Image(systemName: subtitlesOn ? "captions.bubble.fill" : "captions.bubble")
                    .font(.system(size: 18))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.white.opacity(0.15))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Subtitles")
        }
    }
}
