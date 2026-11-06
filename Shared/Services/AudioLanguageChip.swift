import Foundation

extension PlaybackSelection {
    /// The detail page's audio language chip (#828): the language that will
    /// play, and how many other audio languages the file carries.
    struct AudioLanguageChip: Equatable {
        /// The stream's own language code, as the server reported it.
        let languageCode: String
        /// Distinct audio languages other than `languageCode`.
        let otherLanguageCount: Int

        /// "English +1", or just "English" when there is nothing else.
        func text(locale: Locale = .current) -> String {
            let name = locale.localizedString(forLanguageCode: languageCode) ?? languageCode.uppercased()
            return otherLanguageCount > 0 ? "\(name) +\(otherLanguageCount)" : name
        }
    }

    /// Codes that name no language; a stream carrying one is unlabelled.
    private static let noLanguageCodes: Set<String> = ["und", "mis", "zxx", "mul"]

    private static func hasLanguage(_ stream: MediaStream) -> Bool {
        guard let code = stream.language?.trimmingCharacters(in: .whitespaces), !code.isEmpty else { return false }
        return !noLanguageCodes.contains(code.lowercased())
    }

    /// The chip for a source's streams, or nil when the playing audio has no
    /// language to show.
    ///
    /// The playing stream is picked the way playback picks it: the Settings
    /// audio language when the file has it (`audioStreamIndex`), otherwise
    /// the server's default for this source, else the default-flagged
    /// stream, else the first audio stream.
    static func audioLanguageChip(
        streams: [MediaStream],
        defaultAudioStreamIndex: Int?,
        preferredLanguage: String
    ) -> AudioLanguageChip? {
        let audio = streams.filter { $0.type == "Audio" }
        let playing: MediaStream? = {
            if let index = audioStreamIndex(in: streams, session: nil, preferredLanguage: preferredLanguage),
               let match = audio.first(where: { $0.index == index }) {
                return match
            }
            if let index = defaultAudioStreamIndex, let match = audio.first(where: { $0.index == index }) {
                return match
            }
            return audio.first(where: { $0.isDefault == true }) ?? audio.first
        }()
        guard let playing, hasLanguage(playing), let code = playing.language else { return nil }

        var seen: [String] = []
        for stream in audio where hasLanguage(stream) {
            guard let language = stream.language,
                  !languagesMatch(language, code),
                  !seen.contains(where: { languagesMatch($0, language) }) else { continue }
            seen.append(language)
        }
        return AudioLanguageChip(languageCode: code, otherLanguageCount: seen.count)
    }
}

extension MediaSourceInfo {
    /// The detail-page audio language chip for this source (#828).
    func audioLanguageChip(preferredLanguage: String) -> PlaybackSelection.AudioLanguageChip? {
        PlaybackSelection.audioLanguageChip(
            streams: mediaStreams ?? [],
            defaultAudioStreamIndex: defaultAudioStreamIndex,
            preferredLanguage: preferredLanguage
        )
    }
}
