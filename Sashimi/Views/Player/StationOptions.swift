import UIKit

/// Subtitles and audio for a channel. AVKit's transport bar carries these for
/// everything else, but a channel turns that bar off, so a hold on the
/// clickpad opens them here instead.
@MainActor
enum StationOptions {
    static func present(from host: UIViewController, model: PlayerViewModel) {
        guard host.presentedViewController == nil else { return }
        let sheet = UIAlertController(title: "Subtitles & Audio", message: nil, preferredStyle: .actionSheet)

        let subtitle = model.subtitleTracks.first { $0.id == model.selectedSubtitleTrackId }?.displayName ?? "Off"
        if !model.subtitleTracks.isEmpty {
            sheet.addAction(UIAlertAction(title: "Subtitles: \(subtitle)", style: .default) { _ in
                let pick = UIAlertController(title: "Subtitles", message: nil, preferredStyle: .actionSheet)
                for track in model.subtitleTracks {
                    let mark = track.id == model.selectedSubtitleTrackId ? "✓ " : ""
                    pick.addAction(UIAlertAction(title: mark + track.displayName, style: .default) { _ in
                        model.selectSubtitleTrack(track)
                    })
                }
                pick.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                host.present(pick, animated: true)
            })
        }

        let audio = model.audioTracks.first { $0.id == model.selectedAudioTrackId }?.displayName ?? "Default"
        if model.audioTracks.count > 1 {
            sheet.addAction(UIAlertAction(title: "Audio: \(audio)", style: .default) { _ in
                let pick = UIAlertController(title: "Audio", message: nil, preferredStyle: .actionSheet)
                for track in model.audioTracks {
                    let mark = track.id == model.selectedAudioTrackId ? "✓ " : ""
                    pick.addAction(UIAlertAction(title: mark + track.displayName, style: .default) { _ in
                        model.selectAudioTrack(track)
                    })
                }
                pick.addAction(UIAlertAction(title: "Cancel", style: .cancel))
                host.present(pick, animated: true)
            })
        }

        if sheet.actions.isEmpty {
            sheet.message = "This programme has no subtitles or other audio tracks."
        }
        sheet.addAction(UIAlertAction(title: "Close", style: .cancel))
        host.present(sheet, animated: true)
    }
}
