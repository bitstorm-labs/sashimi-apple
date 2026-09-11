import AVKit
import SwiftUI

extension TVPlayerView {
    // MARK: - Transport Bar Menus

    func buildMenus(includeAudio: Bool = false) -> [UIMenuElement] {
        var menus: [UIMenuElement] = []

        // Speed menu
        let speeds: [(String, Float)] = [
            ("0.5×", 0.5), ("0.75×", 0.75), ("1× Normal", 1.0),
            ("1.25×", 1.25), ("1.5×", 1.5), ("2×", 2.0)
        ]
        let currentRate = player.rate != 0 ? player.rate : 1.0
        let speedActions = speeds.map { title, rate in
            UIAction(
                title: title,
                state: currentRate == rate ? .on : .off
            ) { _ in
                player.rate = rate
            }
        }
        let speedMenu = UIMenu(
            title: "Speed",
            image: UIImage(systemName: "speedometer"),
            children: speedActions
        )
        menus.append(speedMenu)

        if includeAudio { menus.append(audioMenu()) }

        // Subtitles menu
        let subtitleActions = viewModel.subtitleTracks.map { track in
            UIAction(
                title: track.displayName,
                state: track.id == viewModel.selectedSubtitleTrackId ? .on : .off
            ) { _ in
                viewModel.selectSubtitleTrack(track)
            }
        }
        if !subtitleActions.isEmpty {
            let subtitleMenu = UIMenu(
                title: "Subtitles",
                image: UIImage(systemName: "captions.bubble"),
                children: subtitleActions
            )
            menus.append(subtitleMenu)
        }

        // Quality menu
        let qualityActions = QualityOption.allCases.map { quality in
            UIAction(
                title: quality.displayName,
                state: viewModel.selectedQuality == quality ? .on : .off
            ) { _ in
                Task { await viewModel.changeQuality(quality) }
            }
        }
        let qualityMenu = UIMenu(
            title: "Quality",
            image: UIImage(systemName: "gearshape"),
            children: qualityActions
        )
        menus.append(qualityMenu)

        return menus
    }

    private func audioMenu() -> UIMenu {
        let actions = viewModel.audioTracks.map { track in
            UIAction(
                title: track.displayName,
                state: track.id == viewModel.selectedAudioTrackId ? .on : .off
            ) { _ in
                viewModel.selectAudioTrack(track)
            }
        }
        return UIMenu(title: "Audio", image: UIImage(systemName: "speaker.wave.2"), children: actions)
    }
}
