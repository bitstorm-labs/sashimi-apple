import Foundation

/// Pure reading of a Jellyfin HLS multivariant playlist (Apple's term; Jellyfin
/// still serves it as `master.m3u8`), used to decide whether AVPlayer should
/// be pointed at one media playlist instead of the whole thing.
///
/// Why this exists (#443): for an HDR source that the server is going to
/// stream-copy, Jellyfin's `DynamicHlsHelper` unconditionally appends HDR→SDR
/// fallback variants (`…&AllowVideoStreamCopy=false`) at the *same* BANDWIDTH
/// as the copy variant — "so that the client can choose by other attributes,
/// such as color range". Nothing the device profile declares suppresses them
/// (verified against the `v12.1` tag). All the variants share one transcoding
/// slot and one segment namespace on the server but not one segment grid
/// (copy = 6 s, re-encode = 3 s), so every time AVPlayer switches variant —
/// its opening pick, a seek, a failover after a stall — ffmpeg is restarted
/// with a different codec and grid, the requested segment doesn't exist, and
/// the stream stalls again. 4K HDR could not get through an episode; 1080p
/// SDR (single variant) played fine through the same path.
///
/// Handing AVPlayer the primary variant's media playlist directly leaves it
/// one codec and one grid to work with, which is exactly what the SDR case
/// already has.
enum HLSMultivariantPlaylist {
    struct Variant: Equatable {
        /// The `#EXT-X-STREAM-INF` attribute list, kept for diagnostics.
        let attributes: String
        /// The URI line that follows it, exactly as written.
        let uri: String

        /// Jellyfin marks its HDR→SDR fallback-hack variants by forcing the
        /// stream copy off in the query. A request that *itself* disallowed
        /// stream copy produces a master with only such variants — and no
        /// primary — which is why the caller pins nothing in that case.
        var isStreamCopyFallback: Bool {
            uri.range(of: "AllowVideoStreamCopy=false", options: .caseInsensitive) != nil
        }
    }

    /// Every `#EXT-X-STREAM-INF` entry with its URI. `#EXT-X-IMAGE-STREAM-INF`
    /// (trickplay) and `#EXT-X-MEDIA` carry their URI as an attribute and are
    /// not variants.
    static func variants(in playlist: String) -> [Variant] {
        var variants: [Variant] = []
        var pendingAttributes: String?
        for rawLine in playlist.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingAttributes = String(line.dropFirst("#EXT-X-STREAM-INF:".count))
            } else if line.hasPrefix("#") || line.isEmpty {
                // A tag or comment between STREAM-INF and its URI is legal;
                // keep waiting for the URI line.
                continue
            } else if let attributes = pendingAttributes {
                variants.append(Variant(attributes: attributes, uri: line))
                pendingAttributes = nil
            }
        }
        return variants
    }

    /// The media playlist to hand AVPlayer instead of the master, or nil when
    /// the master should be used as-is.
    ///
    /// Pins only when the fallback hack is present AND there is a primary to
    /// pin to. An adaptive-bitrate ladder (several variants, no fallbacks)
    /// is a legitimate reason for a master and is left alone; so is a master
    /// whose only variants are forced re-encodes (recovery attempt 2). When
    /// the server lists several primaries (Dolby Vision `dvh1` + `hvc1`), it
    /// puts the one it wants Apple clients to take first.
    static func singlePrimaryVariantURL(playlist: String, multivariantURL: URL) -> URL? {
        let variants = variants(in: playlist)
        guard variants.contains(where: \.isStreamCopyFallback),
              let primary = variants.first(where: { !$0.isStreamCopyFallback })
        else { return nil }
        return URL(string: primary.uri, relativeTo: multivariantURL)?.absoluteURL
    }

    /// The master reduced to the one variant `singlePrimaryVariantURL` pins,
    /// with everything else it carries — above all the trickplay
    /// `#EXT-X-IMAGE-STREAM-INF` — kept, and every URI made absolute. Nil when
    /// the master should not be rewritten: no fallback hack to remove, no
    /// primary to keep, or no image stream to keep (then the plain pin loses
    /// nothing and stays the path).
    ///
    /// Why (#449): pinning AVPlayer to the primary's media playlist fixed the
    /// #443 stall but dropped the scrub thumbnails, because Jellyfin
    /// advertises its trickplay tiles only in the master and tvOS's
    /// `AVPlayerViewController` has no API for supplying scrub images any
    /// other way. A master whose only `#EXT-X-STREAM-INF` is the pinned
    /// variant gives AVPlayer exactly one codec and one segment grid — the
    /// same thing the pin gives it — plus the image stream.
    ///
    /// The result is served from memory through a custom URL scheme
    /// (`HLSPlaylistResourceLoader`), so relative URIs would resolve against
    /// that scheme; they are resolved against the real master URL here so
    /// AVPlayer fetches the media playlist, segments and tiles over HTTP as
    /// before. Any tag whose URI is a fallback (`AllowVideoStreamCopy=false`)
    /// is dropped too, so no fallback is reachable from the result.
    static func primaryVariantPlaylistKeepingImageStreams(playlist: String, multivariantURL: URL) -> String? {
        let allVariants = variants(in: playlist)
        guard allVariants.contains(where: \.isStreamCopyFallback),
              let primary = allVariants.first(where: { !$0.isStreamCopyFallback })
        else { return nil }

        let lines = playlist.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U",
              lines.contains(where: { $0.hasPrefix("#EXT-X-IMAGE-STREAM-INF:") })
        else { return nil }

        var output: [String] = []
        // A `#EXT-X-STREAM-INF` and any tags between it and its URI line,
        // held until the URI decides whether the whole entry is kept.
        var pendingVariant: [String]?
        var keptPrimary = false
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingVariant = [line]
            } else if var entry = pendingVariant {
                if line.hasPrefix("#") || line.isEmpty {
                    entry.append(line)
                    pendingVariant = entry
                    continue
                }
                pendingVariant = nil
                guard !keptPrimary, line == primary.uri,
                      let absolute = absoluteURI(line, relativeTo: multivariantURL)
                else { continue }
                keptPrimary = true
                output.append(contentsOf: entry)
                output.append(absolute)
            } else if line.hasPrefix("#") {
                guard let rewritten = absolutizingURIAttribute(in: line, relativeTo: multivariantURL) else { continue }
                output.append(rewritten)
            } else if line.isEmpty {
                output.append(line)
            }
            // A bare URI line outside a variant entry is malformed in a
            // multivariant playlist; it is dropped rather than guessed at.
        }
        guard keptPrimary else { return nil }
        while output.last?.isEmpty == true { output.removeLast() }
        return output.joined(separator: "\n") + "\n"
    }

    private static func absoluteURI(_ uri: String, relativeTo base: URL) -> String? {
        guard uri.range(of: "AllowVideoStreamCopy=false", options: .caseInsensitive) == nil else { return nil }
        return URL(string: uri, relativeTo: base)?.absoluteURL.absoluteString
    }

    /// A tag line with its `URI="…"` attribute (if any) made absolute, or nil
    /// when the line must be dropped: the URI points at a fallback or cannot
    /// be resolved.
    private static func absolutizingURIAttribute(in line: String, relativeTo base: URL) -> String? {
        let pattern = #"(?<=[:,])URI="([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let whole = Range(match.range, in: line),
              let value = Range(match.range(at: 1), in: line)
        else { return line }
        guard let absolute = absoluteURI(String(line[value]), relativeTo: base) else { return nil }
        return line.replacingCharacters(in: whole, with: "URI=\"\(absolute)\"")
    }
}
