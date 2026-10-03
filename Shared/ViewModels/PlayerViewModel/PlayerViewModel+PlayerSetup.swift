import Foundation
import AVFoundation
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "PlayerViewModel")

extension PlayerViewModel {
    /// Shared player setup: resolves stream URL, creates AVPlayer with observers.
    /// `allowVideoStreamCopy` is only ever false on the second recovery
    /// attempt (see attemptPlaybackRecovery) — the normal path always permits
    /// the server to copy the video stream untouched.
    func setupPlayer( // swiftlint:disable:this function_body_length
        for item: BaseItemDto,
        maxBitrate: Int? = nil,
        maxWidth: Int? = nil,
        forceTranscode: Bool = false,
        allowVideoStreamCopy: Bool = true,
        expectedPlaybackGeneration: PlaybackGeneration? = nil
    ) async throws {
        // Bitrate precedence: explicit override (quality menu change) →
        // session quality selection → global Settings cap. QualityOption.auto
        // has a nil bitrate, so "Auto" defers to Settings, where 0 = no cap.
        let effectiveBitrate = PlaybackSelection.effectiveMaxBitrate(
            sessionOverride: maxBitrate ?? selectedQuality.maxBitrate,
            settingsMaxBitrate: playbackSettings.maxBitrate
        )
        // The session tier's width travels with its bitrate (the next episode
        // after a pick or a step-down loads through here with no explicit
        // width; the two 720p/480p tiers differ only in bitrate, so a width
        // derived from the bitrate alone would not match the tier).
        let maxWidth = maxWidth ?? selectedQuality.maxWidth

        // The cap in force, and whether it came from a real measurement or a
        // default (the #341/#342 Auto-cap work). An unexplained transcode is
        // almost always this value, and it was previously only visible in the
        // JellyfinClient log, disconnected from the play attempt it belonged to.
        let bandwidth = await client.bandwidthStatus
        try requireCurrentPlaybackGeneration(expectedPlaybackGeneration)
        diag(.playbackInfoRequest, [
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("itemType", item.type?.rawValue),
            PlayerDiagnostics.field("requestedBitrate", effectiveBitrate),
            PlayerDiagnostics.field("effectiveCap", effectiveBitrate ?? bandwidth.cap),
            PlayerDiagnostics.field("capSource", effectiveBitrate != nil ? "explicit" : (bandwidth.isMeasured ? "measured" : "default")),
            PlayerDiagnostics.field("measuredBitrate", bandwidth.measuredBitrate),
            PlayerDiagnostics.field("localServer", bandwidth.isLocalServer),
            PlayerDiagnostics.field("maxWidth", maxWidth),
            PlayerDiagnostics.field("forceTranscode", forceTranscode),
            PlayerDiagnostics.field("forceDirectPlay", playbackSettings.forceDirectPlay),
            // Video stream-copy is normally allowed (see getPlaybackInfo): the
            // Apple TV decodes the source codec natively, so the server remuxes
            // + copies rather than re-encodes. False only on the second
            // recovery attempt — the stream-copy HLS seek-freeze
            // (jellyfin#16070, #4188) is handled by the error/stall recovery
            // fallback (attemptPlaybackRecovery), the official-client pattern.
            PlayerDiagnostics.field("allowVideoStreamCopy", allowVideoStreamCopy)
        ])

        // Phase 1 of the VLC work: the profile can be VLC-shaped for
        // observation, but the player below is still AVPlayer either way.
        let engine: PlaybackEngineKind = playbackSettings.debugVLCDeviceProfile ? .vlc : .avFoundation

        var playbackInfo = try await client.getPlaybackInfo(
            itemId: item.id,
            itemType: item.type,
            engine: engine,
            maxBitrate: effectiveBitrate,
            maxWidth: maxWidth,
            forceDirectPlay: playbackSettings.forceDirectPlay,
            forceTranscode: forceTranscode,
            allowVideoStreamCopy: allowVideoStreamCopy
        )
        try requireCurrentPlaybackGeneration(expectedPlaybackGeneration)

        // Source-aware retry (Auto path only). The source bitrate is only known
        // from the response, so it takes a second pass: if the link cannot carry
        // this source the server returns a transcode, and left alone that is a
        // heavy, stutter/OOM-prone full-4K re-encode riding the link ceiling
        // (a ~72 Mbps Wi-Fi link vs a 68.8 Mbps 4K remux). Re-request a light
        // 1080p the link comfortably holds. A copyable source never reaches here
        // (no transcodingUrl, or cap >= source), so a wired/fast client keeps
        // native 4K; explicit quality picks and forceTranscode are untouched.
        var requestedBitrateCap: Int?
        if effectiveBitrate == nil, maxWidth == nil, !forceTranscode,
           let source = playbackInfo.mediaSources?.first,
           source.transcodingUrl?.isEmpty == false,
           let override = PlaybackSelection.constrainedAutoOverride(cap: bandwidth.cap, sourceBitrate: source.bitrate, isWired: bandwidth.isWired) {
            diag(.playbackInfoRequest, [
                PlayerDiagnostics.field("phase", "constrained-retry"),
                PlayerDiagnostics.field("sourceBitrate", source.bitrate),
                PlayerDiagnostics.field("cap", bandwidth.cap),
                PlayerDiagnostics.field("isWired", bandwidth.isWired),
                PlayerDiagnostics.field("retryWidth", override.maxWidth),
                PlayerDiagnostics.field("retryBitrate", override.maxBitrate)
            ])
            requestedBitrateCap = override.maxBitrate
            playbackInfo = try await client.getPlaybackInfo(
                itemId: item.id,
                itemType: item.type,
                engine: engine,
                maxBitrate: override.maxBitrate,
                maxWidth: override.maxWidth,
                forceDirectPlay: playbackSettings.forceDirectPlay,
                forceTranscode: forceTranscode,
                allowVideoStreamCopy: allowVideoStreamCopy
            )
            try requireCurrentPlaybackGeneration(expectedPlaybackGeneration)
        }

        activeBitrateCap = requestedBitrateCap ?? effectiveBitrate ?? bandwidth.cap

        guard let mediaSource = playbackInfo.mediaSources?.first else {
            diagFailure(.playbackInfoResponse, [
                PlayerDiagnostics.field("item", item.id),
                PlayerDiagnostics.field("outcome", "no-media-source"),
                PlayerDiagnostics.field("sourceCount", playbackInfo.mediaSources?.count ?? 0)
            ])
            throw PlayerError.noMediaSource
        }

        diag(.playbackInfoResponse, [
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("mediaSource", mediaSource.id),
            PlayerDiagnostics.field("playSession", playbackInfo.playSessionId),
            PlayerDiagnostics.field("container", mediaSource.container),
            PlayerDiagnostics.field("supportsDirectPlay", mediaSource.supportsDirectPlay),
            PlayerDiagnostics.field("supportsDirectStream", mediaSource.supportsDirectStream),
            PlayerDiagnostics.field("supportsTranscoding", mediaSource.supportsTranscoding),
            PlayerDiagnostics.field("hasTranscodingUrl", mediaSource.transcodingUrl?.isEmpty == false),
            PlayerDiagnostics.field("hasDirectStreamUrl", mediaSource.directStreamUrl?.isEmpty == false),
            PlayerDiagnostics.field("videoCodec", mediaSource.videoCodec),
            PlayerDiagnostics.field("audioCodec", mediaSource.audioCodec),
            PlayerDiagnostics.field("sourceBitrate", mediaSource.bitrate),
            PlayerDiagnostics.field("resolution", mediaSource.videoResolution),
            PlayerDiagnostics.field("transcodeReasons", mediaSource.transcodeReasons?.joined(separator: ",") ?? "none")
        ])

        let resolvedURL: URL?
        let streamKind: PlayerDiagnostics.StreamKind
        // Only meaningful for `.transcodeHLS`: whether AVPlayer gets one media
        // playlist pinned out of the master (see `HLSMultivariantPlaylist`, #443).
        var pinnedHLSVariant = false
        // The pinned master with its trickplay image stream kept (#449).
        var pinnedMultivariantPlaylist: String?
        if let transcodingPath = mediaSource.transcodingUrl, !transcodingPath.isEmpty {
            streamKind = .transcodeHLS
            let resolution = await client.resolveHLSStreamURL(transcodingPath: transcodingPath)
            resolvedURL = resolution?.url
            pinnedHLSVariant = resolution?.pinnedVariant ?? false
            pinnedMultivariantPlaylist = resolution?.pinnedMultivariantPlaylist
            try requireCurrentPlaybackGeneration(expectedPlaybackGeneration)
        } else if let directPath = mediaSource.directStreamUrl, !directPath.isEmpty {
            streamKind = .directStream
            resolvedURL = await client.buildURL(path: directPath)
            try requireCurrentPlaybackGeneration(expectedPlaybackGeneration)
        } else if mediaSource.supportsDirectPlay != false {
            streamKind = .directPlayStatic
            resolvedURL = await client.getPlaybackURL(itemId: item.id, mediaSourceId: mediaSource.id, container: mediaSource.container)
            try requireCurrentPlaybackGeneration(expectedPlaybackGeneration)
        } else {
            // The server offered no transcode/remux URL AND says the source
            // can't direct play (e.g. Force Direct Play against a container
            // this device can't decode). The old behavior built a static
            // stream URL anyway — a stream that bypasses the device profile,
            // which is what forces fMP4 for HEVC — and handed AVPlayer a file
            // it can't render: audio over a black screen instead of an error.
            // Fail loudly instead.
            logger.error("Media source \(mediaSource.id, privacy: .public) is not playable: no stream URLs and SupportsDirectPlay=false")
            diagFailure(.streamSelected, [
                PlayerDiagnostics.field("mediaSource", mediaSource.id),
                PlayerDiagnostics.field("outcome", "source-not-playable")
            ])
            throw PlayerError.sourceNotPlayable
        }

        guard let resolvedURL else {
            diagFailure(.streamSelected, [
                PlayerDiagnostics.field("kind", streamKind.rawValue),
                PlayerDiagnostics.field("outcome", "no-stream-url")
            ])
            throw PlayerError.noStreamURL
        }

        try requireCurrentPlaybackGeneration(expectedPlaybackGeneration)
        playSessionId = playbackInfo.playSessionId
        currentMediaSource = mediaSource
        videoResolution = mediaSource.videoResolution
        streamInfo = nil   // stale for the new session; refreshed when the overlay opens

        // Which URL AVPlayer is actually being pointed at. `describe(url:)`
        // keeps the path and drops the query — the query is where api_key lives.
        // `avplayerPlayableContainer` is a pure observation (nothing branches on
        // it): AVPlayer has no Matroska demuxer, so a direct-stream URL ending
        // in .mkv is a stream it cannot render, and that should be visible here
        // rather than inferred from a black screen.
        let container = resolvedURL.pathExtension.lowercased()
        diag(.streamSelected, [
            PlayerDiagnostics.field("kind", streamKind.rawValue),
            PlayerDiagnostics.field("mediaSource", mediaSource.id),
            PlayerDiagnostics.field("playSession", playbackInfo.playSessionId),
            PlayerDiagnostics.field(
                "avplayerPlayableContainer",
                container.isEmpty || container == "m3u8" || DeviceMediaCompatibility.directPlayContainers.contains(container)
            ),
            PlayerDiagnostics.field("pinnedHLSVariant", pinnedHLSVariant),
            PlayerDiagnostics.describe(url: resolvedURL)
        ])

        // NOTE: the full URL deliberately goes no further than AVURLAsset. It
        // used to be retained in a published `attemptedURL` property that
        // nothing ever read — a credential (`api_key`) parked in view-model
        // state, one `Text(...)` away from being on screen.
        let asset: AVURLAsset
        let playlistLoader = Self.pinnedPlaylistLoader(for: pinnedMultivariantPlaylist)
        hlsPlaylistLoader = playlistLoader
        if let playlistLoader {
            asset = playlistLoader.makeAsset()
        } else {
            asset = AVURLAsset(url: resolvedURL)
        }
        diag(.assetCreated, [
            PlayerDiagnostics.field("kind", streamKind.rawValue),
            PlayerDiagnostics.field("chapters", item.chapters?.count ?? 0),
            PlayerDiagnostics.field("pinnedMasterWithImageStream", playlistLoader != nil)
        ])
        let playerItem = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: ["playable", "duration"])

        if let chapters = item.chapters, !chapters.isEmpty,
           let runTimeTicks = item.runTimeTicks {
            let duration = Double(runTimeTicks) / 10_000_000.0
            setupChapterMarkers(on: playerItem, chapters: chapters, duration: duration)
        }

        makePlayerAndObservers(for: playerItem)
    }

    /// The in-memory master to play instead of the pinned media playlist, so
    /// the HDR stream-copy path keeps its scrub thumbnails (#449).
    ///
    /// tvOS only. `AVPlayerViewController` there draws scrub previews from the
    /// master's `#EXT-X-IMAGE-STREAM-INF` and offers no other way to supply
    /// them. iOS keeps the plain media-playlist pin: an AirPlay sender hands
    /// the asset URL to the receiver, which cannot reach this process's
    /// resource loader, so a private-scheme URL would not play there at all.
    nonisolated static func pinnedPlaylistLoader(for playlist: String?) -> HLSPlaylistResourceLoader? {
        #if os(tvOS)
        return playlist.flatMap { HLSPlaylistResourceLoader(playlist: $0) }
        #else
        return nil
        #endif
    }
}
