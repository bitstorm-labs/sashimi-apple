import Foundation

/// Which audio and subtitle streams a PlaybackInfo request asks the server
/// for (#590).
///
/// A Jellyfin HLS transcode or remux carries exactly one audio track, mapped
/// server-side, so the choice has to travel with the request: AVPlayer has
/// nothing to choose between afterwards. The server only honours the indexes
/// when `MediaSourceId` names the source they belong to.
struct StreamTrackRequest: Equatable {
    /// "No subtitle stream". Sent on every request that does not ask for a
    /// burn-in: with the index absent the server falls back to the Jellyfin
    /// user's default subtitle, and when that is an image format it re-encodes
    /// the video with the subtitle burned in. Text subtitles never need an
    /// index, because the app fetches them as VTT and draws them itself.
    static let noSubtitle = -1

    var mediaSourceId: String
    /// Nil leaves the choice to the server (the user's server-side default).
    var audioStreamIndex: Int?
    var subtitleStreamIndex: Int = StreamTrackRequest.noSubtitle

    /// Whether the server is being asked to burn a subtitle into the picture.
    var burnsInSubtitle: Bool { subtitleStreamIndex >= 0 }
}

extension PlaybackSelection {
    /// The viewer's audio pick, described by content (indexes are not stable
    /// across sources).
    struct AudioIntent: Equatable {
        let language: String?
        let displayName: String
    }

    /// The viewer's subtitle pick, described by content.
    struct SubtitleIntent: Equatable {
        let language: String?
        let displayTitle: String?
        let isExternal: Bool
    }

    /// Image-based subtitle formats (PGS, VobSub, DVB): they have no text
    /// form, so the server cannot serve them as VTT and the only way to show
    /// one is to burn it into the video. Mirrors Jellyfin's
    /// `MediaStream.IsTextFormat`; the server reports codecs in either case
    /// ("PGSSUB").
    static func isImageSubtitle(codec: String?) -> Bool {
        let codec = (codec ?? "").lowercased()
        if codec.contains("microdvd") { return false }
        return codec.contains("pgs") || codec.contains("dvd") || codec.contains("dvbsub")
            || codec == "sub" || codec == "sup" || codec == "dvb_subtitle" || codec == "xsub"
    }

    static func isImageSubtitle(_ stream: MediaStream) -> Bool {
        isImageSubtitle(codec: stream.codec)
    }

    /// The audio stream to request: the session's pick (exact name, then
    /// language), else the Settings language. Nil when nothing matches, so the
    /// server's default stands.
    ///
    /// When several streams share the wanted language (a main mix and a
    /// commentary), the one flagged default wins over the first.
    static func audioStreamIndex(
        in streams: [MediaStream],
        session: AudioIntent?,
        preferredLanguage: String
    ) -> Int? {
        let audio = streams.filter { $0.type == "Audio" && $0.index != nil }
        if let session {
            if let exact = audio.first(where: { audioDisplayName(for: $0) == session.displayName }) {
                return exact.index
            }
            if let match = firstAudioStream(in: audio, language: session.language) {
                return match.index
            }
        }
        guard !preferredLanguage.isEmpty else { return nil }
        return firstAudioStream(in: audio, language: preferredLanguage)?.index
    }

    private static func firstAudioStream(in audio: [MediaStream], language: String?) -> MediaStream? {
        let matches = audio.filter { languagesMatch($0.language, language) }
        return matches.first { $0.isDefault == true } ?? matches.first
    }

    /// The name an audio stream carries in the player's Audio menu.
    static func audioDisplayName(for stream: MediaStream) -> String {
        if let title = stream.displayTitle, !title.isEmpty { return title }
        if let language = stream.language, !language.isEmpty {
            return Locale.current.localizedString(forLanguageCode: language) ?? language.uppercased()
        }
        return "Track \(stream.index ?? 0)"
    }

    /// The subtitle index to request: the image stream the session asked for,
    /// otherwise `noSubtitle`. Only an explicit pick this session burns in; the
    /// Settings preference never does (see `preferredSubtitleStream`), because
    /// a burn-in is a full video re-encode.
    static func burnInSubtitleIndex(in streams: [MediaStream], session: SubtitleIntent?) -> Int {
        guard let session,
              let match = matchingSubtitleStream(
                in: streams.filter { $0.type == "Subtitle" },
                language: session.language,
                displayTitle: session.displayTitle,
                isExternal: session.isExternal
              ),
              isImageSubtitle(match),
              let index = match.index else { return StreamTrackRequest.noSubtitle }
        return index
    }

    /// Everything the request needs to say about tracks, resolved against the
    /// streams of the source that will play.
    static func streamTrackRequest(
        mediaSourceId: String,
        streams: [MediaStream],
        audio: AudioIntent?,
        preferredAudioLanguage: String,
        subtitle: SubtitleIntent?
    ) -> StreamTrackRequest {
        StreamTrackRequest(
            mediaSourceId: mediaSourceId,
            audioStreamIndex: audioStreamIndex(in: streams, session: audio, preferredLanguage: preferredAudioLanguage),
            subtitleStreamIndex: burnInSubtitleIndex(in: streams, session: subtitle)
        )
    }

    /// Whether the PlaybackInfo response shows the request has to be made
    /// again: it named a different source (the server ignores both indexes
    /// unless `MediaSourceId` matches), the source's own streams resolve the
    /// subtitle differently, or they resolve an audio stream that is neither
    /// the one sent nor the one the server picked.
    static func needsTrackRetry(
        sent: StreamTrackRequest,
        resolved: StreamTrackRequest,
        serverAudioStreamIndex: Int?
    ) -> Bool {
        if sent.mediaSourceId != resolved.mediaSourceId
            || sent.subtitleStreamIndex != resolved.subtitleStreamIndex { return true }
        guard let wanted = resolved.audioStreamIndex, wanted != sent.audioStreamIndex else { return false }
        return wanted != serverAudioStreamIndex
    }

    // MARK: - Spatial audio

    /// The selected audio stream's position among the file's own audio
    /// tracks, when SpatialAudioBridge should play it as APAC in place of the
    /// server's audio. Nil keeps the server's audio.
    ///
    /// Only a Matroska file whose video the server copies: the library reads
    /// Matroska, and its audio keeps time with stream-copy video. A re-encoded
    /// picture (a bitrate cap, a quality pick, a burned-in subtitle) also
    /// means less than the source should cross the link, while the library
    /// reads the whole file. Jellyfin and Matroska both list the file's audio
    /// tracks in file order, so the position names the Matroska track.
    static func spatialAudioTrackPosition(in source: MediaSourceInfo, tracks: StreamTrackRequest) -> Int? {
        guard source.container?.split(separator: ",").contains("mkv") == true,
              !tracks.burnsInSubtitle,
              let reasons = transcodeReasons(in: source.transcodingUrl),
              !reencodesVideo(reasons) else { return nil }
        let embedded = source.audioStreams.filter { $0.isExternal != true }
        let selected = tracks.audioStreamIndex ?? source.defaultAudioStreamIndex ?? embedded.first?.index
        guard let position = embedded.firstIndex(where: { $0.index == selected }),
              isSpatialAudio(embedded[position]) else { return nil }
        return position
    }

    /// TrueHD Atmos or DTS:X, by the server's label. The library refuses
    /// plain TrueHD and DTS-HD MA only once it has read the file, which would
    /// delay every such title, so unlabelled tracks are not tried.
    static func isSpatialAudio(_ stream: MediaStream) -> Bool {
        let profile = stream.profile ?? ""
        switch stream.codec?.lowercased() {
        case "truehd": return profile.localizedCaseInsensitiveContains("Atmos")
        case "dts": return profile.localizedCaseInsensitiveContains("DTS:X")
        default: return false
        }
    }

    /// The `TranscodeReasons` Jellyfin writes into a transcoding URL. Its
    /// PlaybackInfo JSON leaves them out, so the URL is the place to read them.
    static func transcodeReasons(in transcodingURL: String?) -> [String]? {
        guard let transcodingURL,
              let value = URLComponents(string: transcodingURL)?.queryItems?
                .first(where: { $0.name == "TranscodeReasons" })?.value else { return nil }
        return value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
