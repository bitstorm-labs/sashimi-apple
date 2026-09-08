import AVFoundation
import Foundation
import os

/// Structured, PII-safe logging for the whole playback lifecycle.
///
/// Why this exists: until now the tvOS player logged almost nothing, so a
/// failed play could only be reconstructed from the Jellyfin server's ffmpeg
/// logs — which show the server obeying the client ("Stopping ffmpeg process
/// with q command" means the CLIENT abandoned that transcode) without ever
/// saying which client code path did it or why. Everything here exists to make
/// that answerable from the device alone.
///
/// Reading the logs on a real device (works for Release builds too):
///
///     log stream --predicate 'subsystem == "com.mondominator.sashimi" AND category == "player"' --style compact
///     log show --last 30m --predicate 'subsystem == "com.mondominator.sashimi" AND category == "player"'
///
/// or filter Console.app on the `SASHIMI-PLAYER` prefix.
///
/// **Level policy.** Lifecycle events use `.notice` (os_log default level), so
/// they are captured without enabling anything and survive into the persisted
/// store — `log show` after the fact finds them. Failures use `.error`. Only
/// the high-volume AVPlayerItem access-log sampling uses `.debug`, which is
/// NOT persisted; to see those, stream live with `--level debug`:
///
///     log stream --level debug --predicate 'subsystem == "com.mondominator.sashimi" AND category == "player"'
///
/// **Privacy policy.** Every value logged here is `privacy: .public`, which
/// makes it the caller's job never to hand this type a secret. Stream URLs
/// carry `api_key` in the query string, so a URL is NEVER logged: use
/// `describe(url:)`, which keeps the path and drops the query entirely. Free
/// text that came from the system (error descriptions) goes through `scrub`,
/// which strips anything URL-shaped. Item ids, media source ids and play
/// session ids ARE logged — they are server-side identifiers, not user data,
/// and they are the only way to line a device log up against a server log.
enum PlayerDiagnostics {
    static let subsystem = "com.mondominator.sashimi"
    static let category = "player"

    /// Grep handle. Every line this type emits starts with it.
    static let prefix = "SASHIMI-PLAYER"

    private static let logger = Logger(subsystem: subsystem, category: category)

    // MARK: - Emit

    /// A key lifecycle event. Default os_log level: present in release builds
    /// without any extra configuration.
    static func event(_ stage: Stage, _ fields: [String] = []) {
        logger.notice("\(prefix, privacy: .public) \(stage.rawValue, privacy: .public) \(join(fields), privacy: .public)")
    }

    /// A failure. Same shape as `event`, logged at error level.
    static func failure(_ stage: Stage, _ fields: [String] = []) {
        logger.error("\(prefix, privacy: .public) \(stage.rawValue, privacy: .public) \(join(fields), privacy: .public)")
    }

    /// High-volume detail (AVPlayerItem access-log sampling). Debug level, so
    /// it costs nothing unless someone is actively streaming the log.
    static func detail(_ stage: Stage, _ fields: [String] = []) {
        logger.debug("\(prefix, privacy: .public) \(stage.rawValue, privacy: .public) \(join(fields), privacy: .public)")
    }

    private static func join(_ fields: [String]) -> String {
        fields.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: - Stages

    /// The lifecycle stage a line belongs to. Kept as a closed enum so the
    /// vocabulary stays greppable — `SASHIMI-PLAYER pbinfo.response` finds
    /// every negotiation, across every build.
    enum Stage: String {
        // View lifecycle (who asked for a player, and who took it away)
        case viewTask = "view.task"
        case viewDisappear = "view.disappear"
        case viewDismiss = "view.dismiss"
        case viewError = "view.error"

        // Load lifecycle
        case loadBegin = "load.begin"
        case loadResolved = "load.resolved"
        case loadReady = "load.ready"
        case loadFailed = "load.failed"

        // Server negotiation
        case playbackInfoRequest = "pbinfo.request"
        case playbackInfoResponse = "pbinfo.response"
        case streamSelected = "stream.selected"

        // AVFoundation
        case assetCreated = "asset.created"
        case playerCreated = "player.created"
        case itemStatus = "item.status"
        case playerStatus = "player.status"
        case tracks = "tracks"
        case errorLog = "avlog.error"
        case accessLog = "avlog.access"
        case timeControl = "timecontrol"

        // Playback control
        case play = "play"
        case seek = "seek"
        case qualityChange = "quality.change"
        case playbackEnded = "playback.ended"
        case nextEpisode = "next.episode"

        // Teardown
        case teardown = "teardown"
        case encodingStop = "encoding.stop"
        case deinitialized = "deinit"
    }

    /// Why a player was torn down. The production restart loop looks identical
    /// from the server side whichever of these fired, so the reason has to come
    /// from the client.
    enum TeardownReason: String {
        /// Viewer pressed Menu / Done, or tapped the close button.
        case userStop = "user-stop"
        /// The SwiftUI view left the hierarchy.
        case viewDisappeared = "view-disappeared"
        /// A new item is being loaded into this same view model (auto-play
        /// next, or a replay).
        case newItem = "new-item"
        /// The quality menu rebuilt the player against a new media source.
        case qualityChange = "quality-change"
        /// The error/stall recovery fallback rebuilt the player at the
        /// current position (official-client onPlaybackError pattern).
        case recovery = "recovery"
        /// Playback reached the end of the item.
        case playbackEnded = "playback-ended"
        /// The app moved to the background while a player was presented.
        case sceneBackground = "scene-background"
        /// The view model was deallocated.
        case deallocated = "deallocated"
        /// Caller did not say. Should not appear; if it does, a call site is
        /// missing a reason.
        case unspecified = "unspecified"
    }

    /// Which URL the client actually asked AVPlayer to fetch. The production
    /// evidence showed one attempt against an HLS transcode and a second
    /// against a Matroska remux seconds later — indistinguishable in the app
    /// today, obvious with this field.
    enum StreamKind: String {
        case transcodeHLS = "transcode-hls"
        case directStream = "direct-stream"
        case directPlayStatic = "direct-play-static"
        case localFile = "local-file"
    }

    // MARK: - Field builders

    static func field(_ name: String, _ value: String?) -> String {
        guard let value, !value.isEmpty else { return "\(name)=nil" }
        return "\(name)=\(scrub(value))"
    }

    static func field(_ name: String, _ value: Int?) -> String {
        "\(name)=\(value.map(String.init) ?? "nil")"
    }

    // Optional on purpose: Jellyfin models these as tri-state (true / false /
    // absent), and "the server did not say" is a different diagnostic fact
    // from "the server said false".
    // swiftlint:disable:next discouraged_optional_boolean
    static func field(_ name: String, _ value: Bool?) -> String {
        "\(name)=\(value.map { $0 ? "true" : "false" } ?? "nil")"
    }

    static func field(_ name: String, _ value: Double?) -> String {
        guard let value, value.isFinite else { return "\(name)=nil" }
        return "\(name)=\(String(format: "%.2f", value))"
    }

    // MARK: - Redaction

    private static let urlPattern = try? NSRegularExpression(
        pattern: "[a-zA-Z][a-zA-Z0-9+.-]*://[^\\s\"'<>]+",
        options: []
    )
    private static let secretParamPattern = try? NSRegularExpression(
        pattern: "(?i)\\b(api_key|apikey|x-emby-token|token|access_?token|password)=[^\\s&\"']*",
        options: []
    )

    /// Removes anything URL-shaped or secret-shaped from free text before it is
    /// logged. AVFoundation error descriptions routinely embed the failing
    /// request URL, which for this app carries `api_key` — so every string that
    /// did not originate in our own code goes through here.
    static func scrub(_ text: String) -> String {
        var result = text
        if let urlPattern {
            result = urlPattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "<url-redacted>"
            )
        }
        if let secretParamPattern {
            result = secretParamPattern.stringByReplacingMatches(
                in: result,
                options: [],
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "<secret-redacted>"
            )
        }
        // Collapse newlines so one event stays one log line.
        return result
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The only sanctioned way to describe a stream URL: path and extension
    /// only, with the query string reduced to a parameter count. The query is
    /// where `api_key` lives, so it is dropped wholesale rather than filtered —
    /// an allowlist would leak the day Jellyfin adds a new auth parameter.
    static func describe(url: URL?) -> String {
        guard let url else { return "path=nil" }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "path=<unparseable>"
        }
        let queryCount = components.queryItems?.count ?? 0
        let ext = url.pathExtension.isEmpty ? "none" : url.pathExtension
        return "path=\(components.path) ext=\(ext) queryparams=\(queryCount)"
    }

    /// Describes a path taken from a Jellyfin media source (already relative,
    /// but it still carries the api_key query).
    static func describe(streamPath: String?) -> String {
        guard let streamPath, !streamPath.isEmpty else { return "path=nil" }
        let pathOnly = streamPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? streamPath
        let ext = (pathOnly as NSString).pathExtension
        return "path=\(pathOnly) ext=\(ext.isEmpty ? "none" : ext)"
    }

    // MARK: - AVFoundation summaries

    /// Summary of an AVPlayerItem error-log entry.
    ///
    /// This is the layer that explains "it played audio but no picture" and
    /// "it stalled at 43 minutes": AVPlayer records HTTP/transport failures
    /// here without ever moving the item to `.failed`, so nothing in the app
    /// used to see them.
    static func summarize(errorEvent event: AVPlayerItemErrorLogEvent) -> [String] {
        [
            field("errorStatusCode", event.errorStatusCode),
            field("errorDomain", event.errorDomain),
            field("errorComment", event.errorComment),
            field("uri", event.uri == nil ? nil : "<redacted>"),
            field("serverAddress", event.serverAddress == nil ? nil : "<redacted>")
        ]
    }

    /// Summary of an AVPlayerItem access-log entry. `numberOfStalls` climbing
    /// while `observedBitrate` sits below `indicatedBitrate` is the signature of
    /// a link that cannot carry the stream the server was asked to produce.
    static func summarize(accessEvent event: AVPlayerItemAccessLogEvent) -> [String] {
        [
            field("indicatedBitrate", event.indicatedBitrate),
            field("observedBitrate", event.observedBitrate),
            field("switchBitrate", event.switchBitrate),
            field("numberOfStalls", event.numberOfStalls),
            field("numberOfDroppedVideoFrames", event.numberOfDroppedVideoFrames),
            field("durationWatched", event.durationWatched),
            field("segmentsDownloadedDuration", event.segmentsDownloadedDuration),
            field("startupTime", event.startupTime),
            field("playbackType", event.playbackType)
        ]
    }

    /// Counts of the tracks AVPlayer actually decided to render.
    ///
    /// Zero enabled video tracks with one or more enabled audio tracks IS the
    /// audio-only failure, stated directly instead of inferred from the
    /// viewer's description of a black screen.
    struct TrackSummary {
        let videoCount: Int
        let audioCount: Int
        let enabledVideoCount: Int
        let enabledAudioCount: Int
        let presentationWidth: Int
        let presentationHeight: Int

        var fields: [String] {
            [
                PlayerDiagnostics.field("video", videoCount),
                PlayerDiagnostics.field("audio", audioCount),
                PlayerDiagnostics.field("videoEnabled", enabledVideoCount),
                PlayerDiagnostics.field("audioEnabled", enabledAudioCount),
                PlayerDiagnostics.field("presentation", "\(presentationWidth)x\(presentationHeight)"),
                PlayerDiagnostics.field("audioOnly", enabledVideoCount == 0 && enabledAudioCount > 0)
            ]
        }
    }

    /// Reads the track state off a ready item. Uses `AVPlayerItem.tracks`
    /// rather than the asset's tracks on purpose: for HLS the asset exposes no
    /// tracks at all, and HLS is exactly the case being debugged.
    static func trackSummary(for item: AVPlayerItem) -> TrackSummary {
        var video = 0
        var audio = 0
        var enabledVideo = 0
        var enabledAudio = 0

        for track in item.tracks {
            switch track.assetTrack?.mediaType {
            case .some(.video):
                video += 1
                if track.isEnabled { enabledVideo += 1 }
            case .some(.audio):
                audio += 1
                if track.isEnabled { enabledAudio += 1 }
            default:
                continue
            }
        }

        let size = item.presentationSize
        return TrackSummary(
            videoCount: video,
            audioCount: audio,
            enabledVideoCount: enabledVideo,
            enabledAudioCount: enabledAudio,
            presentationWidth: Int(size.width),
            presentationHeight: Int(size.height)
        )
    }

    /// Human name for an AVPlayerItem/AVPlayer status.
    static func name(itemStatus: AVPlayerItem.Status) -> String {
        switch itemStatus {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "unhandled(\(itemStatus.rawValue))"
        }
    }

    static func name(playerStatus: AVPlayer.Status) -> String {
        switch playerStatus {
        case .unknown: return "unknown"
        case .readyToPlay: return "readyToPlay"
        case .failed: return "failed"
        @unknown default: return "unhandled(\(playerStatus.rawValue))"
        }
    }

    static func name(timeControlStatus: AVPlayer.TimeControlStatus) -> String {
        switch timeControlStatus {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        case .playing: return "playing"
        @unknown default: return "unhandled(\(timeControlStatus.rawValue))"
        }
    }

    /// Domain/code/description for an error, with the description scrubbed.
    /// The domain and code are the parts that identify the failure
    /// (`CoreMediaErrorDomain -12939` etc.); the description is the part that
    /// can contain a URL.
    static func fields(for error: Error?) -> [String] {
        guard let error else { return [field("error", "none")] }
        let nsError = error as NSError
        var out = [
            field("errorDomain", nsError.domain),
            field("errorCode", nsError.code),
            field("errorDescription", nsError.localizedDescription)
        ]
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError {
            out.append(field("underlyingDomain", underlying.domain))
            out.append(field("underlyingCode", underlying.code))
        }
        return out
    }
}
