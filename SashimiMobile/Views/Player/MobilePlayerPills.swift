import AVKit
import SwiftUI

/// The player's bottom row of rounded pill buttons, the house style shared
/// with the Roku OSD: Subtitles, Audio, Quality, Speed, View Mode, then
/// Picture in Picture and AirPlay. Each pill is one menu; the old gear menu's
/// sections became pills of their own.
struct MobilePlayerPillRow: View {
    @ObservedObject var viewModel: PlayerViewModel
    @ObservedObject var viewModes: VideoViewModeStore
    @ObservedObject var pictureInPicture: PictureInPictureModel
    /// Downloaded playback: there is no server stream to change quality on.
    let isOffline: Bool
    @Binding var playbackSpeed: Float
    /// Any touch on the row, so the overlay's auto-hide timer restarts.
    var onInteract: () -> Void = {}

    static let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        // Labelled pills where they fit (iPad, iPhone landscape); icons alone
        // on a narrow phone rather than a row that runs off the screen.
        ViewThatFits(in: .horizontal) {
            row(showsTitles: true)
            row(showsTitles: false)
        }
        .disabled(viewModel.transitionState.isTransitioning)
        .simultaneousGesture(TapGesture().onEnded(onInteract))
    }

    private func row(showsTitles: Bool) -> some View {
        HStack(spacing: 10) {
            subtitlesPill(showsTitles)
            if !viewModel.audioTracks.isEmpty {
                audioPill(showsTitles)
            }
            if !isOffline {
                qualityPill(showsTitles)
            }
            speedPill(showsTitles)
            viewModePill(showsTitles)
            Spacer(minLength: 0)
            if pictureInPicture.isSupported {
                pictureInPicturePill
            }
            AirPlayPill()
        }
    }

    // MARK: Subtitles

    private var subtitleTracks: [SubtitleTrackOption] {
        viewModel.subtitleTracks.filter { !$0.isOffOption }
    }

    private var subtitlesOn: Bool {
        guard let id = viewModel.selectedSubtitleTrackId else { return false }
        return id != "off"
    }

    private func subtitlesPill(_ showsTitle: Bool) -> some View {
        Menu {
            // Route through the view model so the overlay is cleared too.
            checkButton("Off", isOn: !subtitlesOn) { viewModel.disableSubtitles() }
            ForEach(subtitleTracks) { track in
                checkButton(track.displayName, isOn: viewModel.selectedSubtitleTrackId == track.id) {
                    viewModel.selectSubtitleTrack(track)
                }
            }
        } label: {
            PlayerPillLabel(
                title: "Subtitles",
                systemImage: subtitlesOn ? "captions.bubble.fill" : "captions.bubble",
                showsTitle: showsTitle
            )
        }
        .disabled(subtitleTracks.isEmpty)
        .accessibilityLabel("Subtitles")
    }

    // MARK: Audio

    private func audioPill(_ showsTitle: Bool) -> some View {
        Menu {
            ForEach(viewModel.audioTracks) { track in
                checkButton(track.displayName, isOn: viewModel.selectedAudioTrackId == track.id) {
                    viewModel.selectAudioTrack(track)
                }
            }
        } label: {
            PlayerPillLabel(title: "Audio", systemImage: "speaker.wave.2", showsTitle: showsTitle)
        }
        .accessibilityLabel("Audio")
    }

    // MARK: Quality

    private func qualityPill(_ showsTitle: Bool) -> some View {
        Menu {
            Section("Now: \(viewModel.qualityStatusLabel)") {
                ForEach(QualityOption.standardTiers) { quality in
                    qualityButton(quality)
                }
            }
            Section("Low bandwidth") {
                ForEach(QualityOption.lowBandwidthTiers) { quality in
                    qualityButton(quality)
                }
            }
        } label: {
            // The pill names the quality in force, so a pick visibly lands.
            PlayerPillLabel(title: viewModel.qualityStatusLabel, systemImage: "gearshape", showsTitle: showsTitle)
        }
        .accessibilityLabel("Quality")
        .accessibilityValue(viewModel.qualityStatusLabel)
    }

    private func qualityButton(_ quality: QualityOption) -> some View {
        checkButton(quality.menuTitle, isOn: viewModel.selectedQuality == quality) {
            Task { await viewModel.changeQuality(quality) }
        }
    }

    // MARK: Speed

    private func speedPill(_ showsTitle: Bool) -> some View {
        Menu {
            ForEach(Self.speeds, id: \.self) { speed in
                checkButton(Self.speedName(speed), isOn: playbackSpeed == speed) {
                    playbackSpeed = speed
                    // defaultRate keeps the speed across pause/play
                    viewModel.player?.defaultRate = speed
                    if viewModel.player?.rate != 0 {
                        viewModel.player?.rate = speed
                    }
                }
            }
        } label: {
            PlayerPillLabel(
                title: playbackSpeed == 1.0 ? "Speed" : Self.speedName(playbackSpeed),
                systemImage: "speedometer",
                showsTitle: showsTitle
            )
        }
        .accessibilityLabel("Playback Speed")
    }

    static func speedName(_ speed: Float) -> String {
        speed == 1.0 ? "Normal" : String(format: "%g×", speed)
    }

    // MARK: View Mode

    /// Normal, Zoom or Stretch for this session, plus "Use for All Videos",
    /// the same choices as the tvOS View Mode menu.
    private func viewModePill(_ showsTitle: Bool) -> some View {
        Menu {
            Section {
                ForEach(VideoViewMode.allCases) { mode in
                    checkButton(mode.displayName, isOn: viewModes.activeMode == mode) {
                        viewModes.choose(mode)
                    }
                }
            }
            Section("Default: \(viewModes.defaultMode.displayName)") {
                checkButton("Use for All Videos", isOn: viewModes.activeMode == viewModes.defaultMode) {
                    viewModes.useActiveModeForAllVideos()
                }
            }
        } label: {
            PlayerPillLabel(title: "View", systemImage: "aspectratio", showsTitle: showsTitle)
        }
        .accessibilityLabel("View Mode")
    }

    // MARK: Picture in Picture

    private var pictureInPicturePill: some View {
        Button {
            onInteract()
            pictureInPicture.toggle()
        } label: {
            PlayerPillLabel(
                title: "Picture in Picture",
                systemImage: pictureInPicture.isActive ? "pip.exit" : "pip.enter",
                showsTitle: false
            )
        }
        .buttonStyle(.plain)
        .disabled(!pictureInPicture.isPossible)
        .opacity(pictureInPicture.isPossible ? 1 : 0.45)
        .accessibilityLabel(pictureInPicture.isActive ? "Exit Picture in Picture" : "Picture in Picture")
    }

    // MARK: Helpers

    private func checkButton(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// One pill: an icon and, where there is room, its name.
struct PlayerPillLabel: View {
    let title: String
    let systemImage: String
    var showsTitle = true

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
            if showsTitle {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, showsTitle ? 14 : 0)
        .frame(minWidth: 40, minHeight: 36)
        .background(Capsule().fill(.white.opacity(0.16)))
        .contentShape(Capsule())
    }
}

/// AirPlay, as a pill. The system route picker draws the icon.
private struct AirPlayPill: View {
    var body: some View {
        AirPlayRoutePicker()
            .frame(width: 40, height: 36)
            .background(Capsule().fill(.white.opacity(0.16)))
            .accessibilityLabel("AirPlay")
    }
}

private struct AirPlayRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = UIColor(MobileColors.accent)
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
