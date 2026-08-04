import Foundation

/// Maps Jellyfin's global `MediaStream.Index` values onto the per-category
/// track offsets a playback engine sees.
///
/// Jellyfin numbers *all* streams of a media source in one global sequence —
/// video, audio, embedded subtitles, and external (sidecar) subtitles share
/// it. An engine that opens the container directly (VLC) numbers tracks by
/// position within the container, per category, and knows nothing about
/// sidecars until they are attached separately. Confusing the two spaces is
/// exactly the off-by-one that selects the commentary track when the user
/// picked Japanese, so this mapping is pure and unit-tested.
///
/// Two deliveries with different math:
/// - **Direct play**: the engine sees every embedded stream in container
///   order, so an embedded stream's per-category offset is its rank among
///   embedded streams of its own type. External streams are excluded — they
///   are attached as playback children and land *after* the embedded tracks,
///   in attach order.
/// - **Transcode (HLS)**: the manifest carries exactly one video and one
///   audio stream (whichever the server selected), so every audio index maps
///   to offset 0 and no embedded subtitles exist.
///
/// This is the estimate phase only. Engines finalize against their real
/// track list once it exists (VLC reports tracks at `.playing`), reconciling
/// by language + codec + order; that reconciliation lives with the engine
/// because its track types are engine-specific.
struct TrackIndexMap: Equatable {
    enum Delivery: Equatable {
        case directPlay
        case transcode
    }

    let delivery: Delivery

    /// Jellyfin global index → per-category offset among *embedded* streams.
    private let audioOffsets: [Int: Int]
    private let subtitleOffsets: [Int: Int]

    /// How many embedded subtitle tracks the container carries. Sidecar
    /// subtitles attached as playback children appear after these.
    let embeddedSubtitleCount: Int

    init(streams: [MediaStream], delivery: Delivery) {
        self.delivery = delivery

        var audio: [Int: Int] = [:]
        var subtitles: [Int: Int] = [:]
        var audioRank = 0
        var subtitleRank = 0

        // Container order is index order for embedded streams; externals can
        // appear anywhere in the global sequence and simply don't count.
        for stream in streams.sorted(by: { ($0.index ?? 0) < ($1.index ?? 0) }) {
            guard stream.isExternal != true, let index = stream.index else { continue }
            switch stream.type?.lowercased() {
            case "audio":
                audio[index] = audioRank
                audioRank += 1
            case "subtitle":
                subtitles[index] = subtitleRank
                subtitleRank += 1
            default:
                break
            }
        }

        switch delivery {
        case .directPlay:
            self.audioOffsets = audio
            self.subtitleOffsets = subtitles
            self.embeddedSubtitleCount = subtitleRank
        case .transcode:
            // The HLS manifest has one audio track regardless of which
            // Jellyfin stream it came from, and embeds no subtitles.
            self.audioOffsets = audio.mapValues { _ in 0 }
            self.subtitleOffsets = [:]
            self.embeddedSubtitleCount = 0
        }
    }

    /// Per-category offset for an embedded audio stream, or nil when the
    /// index doesn't name an embedded audio stream of this source.
    func audioOffset(forJellyfinIndex index: Int) -> Int? {
        audioOffsets[index]
    }

    /// Per-category offset for an embedded subtitle stream, or nil for
    /// external subtitles and unknown indexes.
    func subtitleOffset(forJellyfinIndex index: Int) -> Int? {
        subtitleOffsets[index]
    }

    /// Offset a sidecar subtitle lands at after being attached as the
    /// `position`-th playback child (0-based, in attach order).
    func sidecarSubtitleOffset(attachPosition position: Int) -> Int {
        embeddedSubtitleCount + position
    }
}
