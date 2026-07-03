import Foundation

/// Pure selection logic for playback: bitrate caps and track matching.
/// Kept free of AVFoundation/UI types so it can be unit tested directly.
enum PlaybackSelection {
    /// Resolves the bitrate cap sent to the server.
    ///
    /// Precedence: a per-session override (the player's quality menu) wins
    /// over the global Settings value. A settings value of 0 means
    /// "Auto" — no cap — and maps to nil.
    static func effectiveMaxBitrate(sessionOverride: Int?, settingsMaxBitrate: Int) -> Int? {
        if let sessionOverride {
            return sessionOverride
        }
        return settingsMaxBitrate > 0 ? settingsMaxBitrate : nil
    }

    /// Case-insensitive language comparison tolerant of ISO 639-1 vs 639-2
    /// codes: Jellyfin streams report three-letter codes ("eng"), while the
    /// settings picker and AVFoundation locales use two-letter codes ("en").
    static func languagesMatch(_ first: String?, _ second: String?) -> Bool {
        guard let first, let second, !first.isEmpty, !second.isEmpty else { return false }
        return normalizedLanguageCode(first) == normalizedLanguageCode(second)
    }

    /// Which subtitle stream to pre-select when playback starts, or nil for
    /// no subtitles. Preference order: the user's preferred language, then
    /// the stream the server flags as default, then the first stream.
    static func preferredSubtitleStream(
        from streams: [MediaStream],
        preferredLanguage: String,
        subtitlesEnabled: Bool
    ) -> MediaStream? {
        guard subtitlesEnabled, !streams.isEmpty else { return nil }

        if !preferredLanguage.isEmpty,
           let match = streams.first(where: { languagesMatch($0.language, preferredLanguage) }) {
            return match
        }
        return streams.first { $0.isDefault == true } ?? streams.first
    }

    /// Finds the stream in a (possibly new) media source that corresponds to
    /// a previously selected subtitle track. Stream indexes are NOT stable
    /// across media sources (a quality change or next episode returns a new
    /// source), so matching is by content, strictest first:
    /// language + external flag + display title, then language + external
    /// flag, then language alone. Streams without an index are skipped —
    /// they can't be addressed for playback.
    static func matchingSubtitleStream(
        in streams: [MediaStream],
        language: String?,
        displayTitle: String?,
        isExternal: Bool
    ) -> MediaStream? {
        let candidates = streams.filter { $0.index != nil && languagesMatch($0.language, language) }

        if let displayTitle,
           let match = candidates.first(where: { ($0.isExternal ?? false) == isExternal && $0.displayTitle == displayTitle }) {
            return match
        }
        if let match = candidates.first(where: { ($0.isExternal ?? false) == isExternal }) {
            return match
        }
        return candidates.first
    }

    /// Index of the audio option matching the preferred language, given the
    /// language codes of the available options (in order). Returns nil when
    /// no preference is set or nothing matches, so the player's default
    /// audio selection stands.
    static func preferredAudioOptionIndex(languageCodes: [String?], preferredLanguage: String) -> Int? {
        guard !preferredLanguage.isEmpty else { return nil }
        return languageCodes.firstIndex { languagesMatch($0, preferredLanguage) }
    }

    /// Normalizes a language code to ISO 639-1 (alpha-2) where possible,
    /// falling back to the lowercased input for codes Foundation can't map.
    private static func normalizedLanguageCode(_ code: String) -> String {
        let lowered = code.lowercased()
        if let alpha2 = Locale.LanguageCode(lowered).identifier(.alpha2) {
            return alpha2
        }
        return lowered
    }
}
