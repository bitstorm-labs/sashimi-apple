import Foundation

enum DownloadURLBuilder {
    // MARK: - Video Download URLs

    /// Build URL for downloading video at original quality (direct file download)
    static func originalDownloadURL(itemId: String) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL"),
              let accessToken = KeychainHelper.get(forKey: "accessToken") else {
            return nil
        }

        var components = URLComponents(string: serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        components?.path += "/Items/\(itemId)/Download"
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: accessToken)
        ]
        return components?.url
    }

    /// Build URL for downloading video at a specific bitrate (transcoded to mp4)
    static func transcodedDownloadURL(itemId: String, maxBitrate: Int) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL"),
              let accessToken = KeychainHelper.get(forKey: "accessToken") else {
            return nil
        }

        let deviceId = UserDefaults.standard.string(forKey: "deviceId") ?? UUID().uuidString

        var components = URLComponents(string: serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        components?.path += "/Videos/\(itemId)/stream.mp4"
        components?.queryItems = [
            URLQueryItem(name: "MediaSourceId", value: itemId),
            URLQueryItem(name: "MaxStreamingBitrate", value: "\(maxBitrate)"),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "Container", value: "mp4"),
            URLQueryItem(name: "api_key", value: accessToken),
            URLQueryItem(name: "DeviceId", value: deviceId)
        ]
        return components?.url
    }

    /// Build download URL based on quality selection
    static func downloadURL(itemId: String, quality: DownloadQuality) -> URL? {
        if let maxBitrate = quality.maxBitrate {
            return transcodedDownloadURL(itemId: itemId, maxBitrate: maxBitrate)
        }
        return originalDownloadURL(itemId: itemId)
    }

    // MARK: - Subtitle URLs

    /// Build URL for downloading a subtitle track as WebVTT
    static func subtitleURL(itemId: String, subtitleIndex: Int) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL"),
              let accessToken = KeychainHelper.get(forKey: "accessToken") else {
            return nil
        }

        var components = URLComponents(
            string: serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        components?.path += "/Videos/\(itemId)/\(itemId)/Subtitles/\(subtitleIndex)/Stream.vtt"
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: accessToken)
        ]
        return components?.url
    }

    // MARK: - Image URLs

    /// Build URL for downloading poster image
    static func posterURL(itemId: String, maxWidth: Int = 400) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else {
            return nil
        }

        var components = URLComponents(
            string: serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        components?.path += "/Items/\(itemId)/Images/Primary"
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)"),
            URLQueryItem(name: "quality", value: "90")
        ]
        return components?.url
    }

    /// Build URL for downloading backdrop image
    static func backdropURL(itemId: String, maxWidth: Int = 1280) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else {
            return nil
        }

        var components = URLComponents(
            string: serverURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        )
        components?.path += "/Items/\(itemId)/Images/Backdrop"
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)"),
            URLQueryItem(name: "quality", value: "80")
        ]
        return components?.url
    }
}
