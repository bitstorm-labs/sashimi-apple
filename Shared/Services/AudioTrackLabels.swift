import AVFoundation
import Foundation

/// The names the Audio pickers show (#808). A file with two English tracks
/// listed both as "English"; when names collide, each gets what tells it
/// apart: the stream's Title ("Commentary"), then codec and channels
/// ("AC3 5.1", "AAC Stereo"). Names that are already unique are left alone.
///
/// Only the picker label changes. `AudioTrackOption.displayName` stays the
/// name that track selection matches on.
enum AudioTrackLabels {
    /// What can tell one audio track from another.
    struct Details: Equatable {
        var title: String?
        var codec: String?
        /// The codec profile, for Atmos, DTS:X and DTS-HD MA.
        var profile: String?
        var channels: Int?

        init(title: String? = nil, codec: String? = nil, profile: String? = nil, channels: Int? = nil) {
            self.title = title
            self.codec = codec
            self.profile = profile
            self.channels = channels
        }
    }

    private static let separator = " · "

    /// One label per name, in order. `details` lines up with `names`; a
    /// missing entry counts as nothing known.
    static func labels(names: [String], details: [Details]) -> [String] {
        var labels = names
        let groups = Dictionary(grouping: names.indices) { names[$0].lowercased() }
        for indices in groups.values where indices.count > 1 {
            let info = indices.map { $0 < details.count ? details[$0] : Details() }
            let name = { (position: Int) in names[indices[position]] }

            // The Title alone, then Title plus format, then the track number.
            let byTitle = info.indices.map { join(name($0), titlePart(info[$0], name: name($0))) }
            let byFormat = info.indices.map {
                join(name($0), titlePart(info[$0], name: name($0)), formatPart(info[$0]))
            }
            let chosen: [String]
            if isUnique(byTitle) {
                chosen = byTitle
            } else if isUnique(byFormat) {
                chosen = byFormat
            } else {
                chosen = info.indices.map { join(byFormat[$0], "Track \(indices[$0] + 1)") }
            }
            for (position, index) in indices.enumerated() {
                labels[index] = chosen[position]
            }
        }
        return labels
    }

    /// The tracks with their picker labels filled in.
    static func labelled(_ tracks: [AudioTrackOption], details: [Details]) -> [AudioTrackOption] {
        let names = labels(names: tracks.map(\.displayName), details: details)
        return zip(tracks, names).map { $0.withMenuLabel($1) }
    }

    // MARK: Sources

    static func details(for stream: MediaStream) -> Details {
        Details(title: stream.title, codec: stream.codec, profile: stream.profile, channels: stream.channels)
    }

    /// What AVFoundation knows of a track: its title and its codec. AVPlayer's
    /// own options carry no channel count.
    static func details(for option: AVMediaSelectionOption) -> Details {
        let title = AVMetadataItem.metadataItems(
            from: option.commonMetadata,
            filteredByIdentifier: .commonIdentifierTitle
        ).first?.stringValue
        let codec = option.mediaSubTypes.first.map { fourCharacterCode($0.uint32Value) }
        return Details(title: title, codec: codec)
    }

    /// Details for AVPlayer's options, taken from the server's audio streams
    /// when they are evidently the same tracks (same count, and no language
    /// disagrees), since those also know the channels. Otherwise from the
    /// options themselves.
    static func details(
        for options: [AVMediaSelectionOption],
        sourceStreams: [MediaStream]
    ) -> [Details] {
        let streams = sourceStreams.filter { $0.type == "Audio" }
        let languages = options.map { $0.locale?.language.languageCode?.identifier }
        if streamsMatch(streams, languages: languages) {
            return zip(options, streams).map { option, stream in
                var merged = details(for: stream)
                if merged.title?.isEmpty ?? true { merged.title = details(for: option).title }
                return merged
            }
        }
        return options.map { details(for: $0) }
    }

    /// Whether the server's streams are AVPlayer's options in the same order.
    static func streamsMatch(_ streams: [MediaStream], languages: [String?]) -> Bool {
        guard !streams.isEmpty, streams.count == languages.count else { return false }
        return zip(streams, languages).allSatisfy { stream, language in
            guard let left = alpha3(stream.language), let right = alpha3(language) else { return true }
            return left == right
        }
    }

    // MARK: Formatting

    static func codecName(_ codec: String) -> String {
        let key = codec.trimmingCharacters(in: .whitespaces).lowercased()
        switch key {
        case "aac", "mp4a": return "AAC"
        case "ac3", "ac-3": return "AC3"
        case "eac3", "ec-3": return "E-AC3"
        case "truehd", "mlpa": return "TrueHD"
        case "dts", "dca": return "DTS"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "mp3", ".mp3": return "MP3"
        case "alac": return "ALAC"
        case "vorbis": return "Vorbis"
        case "lpcm": return "PCM"
        default:
            return key.hasPrefix("pcm") ? "PCM" : key.uppercased()
        }
    }

    /// The codec as a picker names it, with what its profile adds:
    /// "E-AC3 Atmos", "TrueHD Atmos", "DTS:X", "DTS-HD MA".
    static func formatName(codec: String, profile: String?) -> String {
        let profile = profile?.lowercased() ?? ""
        if profile.contains("dts:x") { return "DTS:X" }
        if profile.contains("dts-hd ma") { return "DTS-HD MA" }
        let name = codecName(codec)
        return profile.contains("atmos") ? name + " Atmos" : name
    }

    static func channelsName(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    private static func titlePart(_ details: Details, name: String) -> String? {
        guard let title = details.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
              !name.localizedCaseInsensitiveContains(title) else { return nil }
        return title
    }

    private static func formatPart(_ details: Details) -> String? {
        let parts = [
            details.codec.flatMap { $0.isEmpty ? nil : formatName(codec: $0, profile: details.profile) },
            details.channels.flatMap { $0 > 0 ? channelsName($0) : nil }
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.joined(separator: separator)
    }

    private static func isUnique(_ labels: [String]) -> Bool {
        Set(labels.map { $0.lowercased() }).count == labels.count
    }

    private static func alpha3(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code.lowercased() != "und" else { return nil }
        return Locale.Language(identifier: code).languageCode?.identifier(.alpha3) ?? code.lowercased()
    }

    private static func fourCharacterCode(_ value: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) }
        return (String(bytes: bytes, encoding: .ascii) ?? "").trimmingCharacters(in: .whitespaces)
    }
}
