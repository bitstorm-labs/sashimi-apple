import Foundation

/// Which playback engine a request is negotiated for. The device profile sent
/// to Jellyfin is engine-shaped: AVPlayer can only demux MP4-family containers
/// (so MKV must ride the server's HLS remux), while VLC demuxes essentially
/// everything (so MKV direct-plays and the remux — whose seek is broken
/// server-side, jellyfin#16070 — is never built).
///
/// A PlaybackInfo response is only meaningful for the engine whose profile
/// produced it, which is why every `getPlaybackInfo` caller passes one of
/// these explicitly: a File Info sheet that says "will direct play" under a
/// profile the player won't use is a lie.
enum PlaybackEngineKind: String, CaseIterable, Identifiable, Sendable {
    case avFoundation
    case vlc

    var id: String { rawValue }
}
