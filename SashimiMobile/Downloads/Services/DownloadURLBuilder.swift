import Foundation

enum DownloadURLBuilder {
    /// Same persisted device id JellyfinClient uses (it writes this key on
    /// first launch). Persist the fallback too so we never send a different
    /// throwaway id per call, which would register phantom devices server-side.
    private static var deviceId: String {
        if let stored = UserDefaults.standard.string(forKey: "deviceId") {
            return stored
        }
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: "deviceId")
        return newId
    }

    // MARK: - Authorization

    /// Wraps a download URL in a URLRequest that carries the access token in
    /// the X-Emby-Token header instead of an api_key query parameter, so the
    /// token doesn't end up in server/proxy logs. Background download tasks
    /// created from a URLRequest keep their headers across app relaunches,
    /// so resumed downloads stay authenticated.
    static func authorizedRequest(for url: URL, accessToken: String? = nil) -> URLRequest? {
        guard let accessToken = accessToken ?? KeychainHelper.get(forKey: "accessToken") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")
        return request
    }

    // MARK: - Video Download URLs

    /// Build URL for downloading video at original quality.
    ///
    /// NOT the raw-file /Items/{id}/Download: an mkv original (e.g. a 4K DV8.1
    /// HEVC WEBDL) downloads fine but AVPlayer can't render its video — black
    /// screen with audio. Instead ask the transcode pipeline for a stream-copy
    /// REMUX into mp4: identical video/audio bits (no re-encode, no quality
    /// loss — VideoCodec lists the source codecs so copy applies), but in a
    /// container AVPlayer demuxes, with HEVC tagged hvc1. Embedded subtitle
    /// tracks are dropped by the remux; subtitles are downloaded separately as
    /// VTT (subtitleURL), so nothing user-visible is lost.
    static func originalDownloadURL(itemId: String, serverURL: URL? = nil) -> URL? {
        guard let baseURL = resolvedServerURL(serverURL) else { return nil }

        var components = URLComponents(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        components?.path += "/Videos/\(itemId)/stream.mp4"
        components?.queryItems = [
            URLQueryItem(name: "MediaSourceId", value: itemId),
            URLQueryItem(name: "VideoCodec", value: "h264,hevc"),
            URLQueryItem(name: "AudioCodec", value: "aac,ac3,eac3"),
            URLQueryItem(name: "Container", value: "mp4"),
            URLQueryItem(name: "AllowVideoStreamCopy", value: "true"),
            URLQueryItem(name: "AllowAudioStreamCopy", value: "true"),
            URLQueryItem(name: "DeviceId", value: deviceId)
        ]
        return components?.url
    }

    /// Build URL for downloading video transcoded to an h264/aac mp4 at a
    /// quality tier.
    ///
    /// Every encoder input is spelled out with the progressive endpoint's own
    /// parameter names (Jellyfin VideosController.GetVideoStream):
    /// VideoBitRate/AudioBitRate set the encode, MaxWidth/MaxHeight the frame,
    /// AudioChannels/MaxAudioChannels the downmix. MaxStreamingBitrate is NOT
    /// one of them — sending only that left the server with no video bitrate,
    /// and it encoded at 1 kbps and 416 px (see DownloadQuality.videoBitrate).
    static func transcodedDownloadURL(
        itemId: String,
        quality: DownloadQuality,
        serverURL: URL? = nil
    ) -> URL? {
        guard let baseURL = resolvedServerURL(serverURL),
              let videoBitrate = quality.videoBitrate,
              let audioBitrate = quality.audioBitrate else { return nil }

        var components = URLComponents(string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        components?.path += "/Videos/\(itemId)/stream.mp4"
        var query = [
            URLQueryItem(name: "MediaSourceId", value: itemId),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "Container", value: "mp4"),
            URLQueryItem(name: "VideoBitRate", value: "\(videoBitrate)"),
            URLQueryItem(name: "AudioBitRate", value: "\(audioBitrate)"),
            URLQueryItem(name: "DeviceId", value: deviceId)
        ]
        if let maxWidth = quality.maxWidth {
            query.append(URLQueryItem(name: "MaxWidth", value: "\(maxWidth)"))
        }
        if let maxHeight = quality.maxHeight {
            query.append(URLQueryItem(name: "MaxHeight", value: "\(maxHeight)"))
        }
        if let channels = quality.audioChannels {
            query.append(URLQueryItem(name: "AudioChannels", value: "\(channels)"))
            query.append(URLQueryItem(name: "MaxAudioChannels", value: "\(channels)"))
        }
        components?.queryItems = query
        return components?.url
    }

    /// Build download URL based on quality selection
    static func downloadURL(itemId: String, quality: DownloadQuality, serverURL: URL? = nil) -> URL? {
        guard quality != .original else {
            return originalDownloadURL(itemId: itemId, serverURL: serverURL)
        }
        return transcodedDownloadURL(itemId: itemId, quality: quality, serverURL: serverURL)
    }

    // MARK: - Subtitle URLs

    /// Build URL for downloading a subtitle track as WebVTT
    static func subtitleURL(itemId: String, subtitleIndex: Int, serverURL: URL? = nil) -> URL? {
        guard let baseURL = resolvedServerURL(serverURL) else { return nil }
        var components = URLComponents(
            string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        components?.path += "/Videos/\(itemId)/\(itemId)/Subtitles/\(subtitleIndex)/Stream.vtt"
        return components?.url
    }

    // MARK: - Image URLs

    /// Build URL for downloading poster image
    static func posterURL(itemId: String, maxWidth: Int = 400, serverURL: URL? = nil) -> URL? {
        guard let baseURL = resolvedServerURL(serverURL) else { return nil }
        var components = URLComponents(
            string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        components?.path += "/Items/\(itemId)/Images/Primary"
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)"),
            URLQueryItem(name: "quality", value: "90")
        ]
        return components?.url
    }

    /// Build URL for downloading backdrop image
    static func backdropURL(itemId: String, maxWidth: Int = 1280, serverURL: URL? = nil) -> URL? {
        guard let baseURL = resolvedServerURL(serverURL) else { return nil }
        var components = URLComponents(
            string: baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        components?.path += "/Items/\(itemId)/Images/Backdrop"
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)"),
            URLQueryItem(name: "quality", value: "80")
        ]
        return components?.url
    }

    private static func resolvedServerURL(_ serverURL: URL?) -> URL? {
        if let serverURL { return serverURL }
        guard let stored = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        return URL(string: stored)
    }
}
