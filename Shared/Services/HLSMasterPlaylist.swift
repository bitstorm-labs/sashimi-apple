import Foundation

/// Pure reading of a Jellyfin HLS master playlist, used to decide whether
/// AVPlayer should be pointed at one media playlist instead of the master.
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
enum HLSMasterPlaylist {
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
    static func variants(in master: String) -> [Variant] {
        var variants: [Variant] = []
        var pendingAttributes: String?
        for rawLine in master.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
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
    static func singlePrimaryVariantURL(master: String, masterURL: URL) -> URL? {
        let variants = variants(in: master)
        guard variants.contains(where: \.isStreamCopyFallback),
              let primary = variants.first(where: { !$0.isStreamCopyFallback })
        else { return nil }
        return URL(string: primary.uri, relativeTo: masterURL)?.absoluteURL
    }
}
