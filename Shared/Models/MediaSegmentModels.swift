import Foundation

// MARK: - Media Segments (for skip intro/credits)

struct MediaSegmentDto: Identifiable {
    let id: String
    let type: MediaSegmentType
    let startSeconds: Double
    let endSeconds: Double
}

/// The raw values are the Intro Skipper plugin's legacy dictionary keys; the
/// server's native Media Segments API uses different names, mapped below.
enum MediaSegmentType: String {
    case intro = "Introduction"
    case outro = "Credits"
    case preview = "Preview"
    case recap = "Recap"
    case unknown

    var displayName: String {
        switch self {
        case .intro: return "Intro"
        case .outro: return "Credits"
        case .preview: return "Preview"
        case .recap: return "Recap"
        case .unknown: return "Segment"
        }
    }

    /// Maps a `MediaSegmentDto.Type` from `/MediaSegments/{id}`. Commercial
    /// has no skip behaviour in the player, so it lands on `.unknown` — which
    /// the player already declines to skip — rather than a new case.
    init(nativeType: String) {
        switch nativeType {
        case "Intro": self = .intro
        case "Outro": self = .outro
        case "Preview": self = .preview
        case "Recap": self = .recap
        default: self = .unknown
        }
    }
}

/// One entry of the server's native Media Segments API (Jellyfin 10.10+):
/// `GET /MediaSegments/{itemId}` → `{"Items": [...]}`. Every provider — Intro
/// Skipper, SkipMe.db, chapter-derived — writes into this table.
struct MediaSegmentsResponse: Codable {
    let items: [Item]

    struct Item: Codable {
        let id: String
        let itemId: String
        let type: String
        let startTicks: Int64
        let endTicks: Int64

        enum CodingKeys: String, CodingKey {
            case id = "Id"
            case itemId = "ItemId"
            case type = "Type"
            case startTicks = "StartTicks"
            case endTicks = "EndTicks"
        }

        var segment: MediaSegmentDto {
            MediaSegmentDto(
                id: id,
                type: MediaSegmentType(nativeType: type),
                startSeconds: Double(startTicks) / 10_000_000.0,
                endSeconds: Double(endTicks) / 10_000_000.0
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }
}

// Intro-skipper plugin legacy response format: {"Introduction": {"Start": 0, "End": 90}, "Credits": {...}}
struct IntroSkipperSegment: Codable {
    let start: Double
    let end: Double

    enum CodingKeys: String, CodingKey {
        case start = "Start"
        case end = "End"
    }
}
