import AVKit
import SwiftUI

// MARK: - Video surface

/// A view whose backing layer is the player's `AVPlayerLayer`.
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    // swiftlint:disable:next force_cast
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// The picture, and nothing else: every control is drawn by the app.
///
/// This is an `AVPlayerLayer`, not an `AVPlayerViewController`. With its
/// playback controls hidden, AVPlayerViewController on iOS has no public way
/// to start Picture in Picture, and leaving its controls on put a second set
/// of buttons on screen (iPad feedback). `AVPictureInPictureController` on the
/// layer is Apple's documented route for custom controls, so PiP starts from
/// the app's own button.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity
    let pictureInPicture: PictureInPictureModel

    func makeUIView(context: Context) -> PlayerLayerView {
        let view = PlayerLayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        pictureInPicture.attach(to: view.playerLayer)
        return view
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        if view.playerLayer.videoGravity != videoGravity {
            view.playerLayer.videoGravity = videoGravity
        }
    }
}

// MARK: - Picture in Picture

/// Owns the `AVPictureInPictureController` for the player's layer and
/// publishes whether PiP can start and whether it is running.
@MainActor
final class PictureInPictureModel: NSObject, ObservableObject {
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false

    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var layer: AVPlayerLayer?

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(to layer: AVPlayerLayer) {
        guard isSupported, self.layer !== layer else { return }
        self.layer = layer
        let controller = AVPictureInPictureController(playerLayer: layer)
        controller?.delegate = self
        // As before: PiP starts only from the button, never by itself when
        // the app is left (that still stops playback, see MobilePlayerView).
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        possibleObservation = controller?.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
        self.controller = controller
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }
}

// AVKit calls these on the main thread. `isActive` is set synchronously so
// that the scene-phase handler, which runs right after PiP starts when the
// viewer goes home, already sees it.
extension PictureInPictureModel: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated { self.isActive = true }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ controller: AVPictureInPictureController
    ) {
        MainActor.assumeIsolated { self.isActive = false }
    }

    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        MainActor.assumeIsolated { self.isActive = false }
    }

    // The player never leaves the screen while PiP runs (it is a full-screen
    // cover that stays presented), so there is nothing to rebuild.
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
