import Foundation

struct StreamInfo {
    let url: URL
    let isTranscoding: Bool
    let container: String?
    let videoCodec: String?
    let videoResolution: String?
    let audioCodec: String?
    let audioChannels: Int?
    let playSessionId: String?

    struct AudioStream: Identifiable {
        let id: String
        let index: Int
        let codec: String?
        let language: String?
        let displayTitle: String?
        let channels: Int?
        let isDefault: Bool
    }

    struct SubtitleStream: Identifiable {
        let id: String
        let index: Int
        let codec: String?
        let language: String?
        let displayTitle: String?
        let isDefault: Bool
        let isExternal: Bool
    }

    let audioStreams: [AudioStream]
    let subtitleStreams: [SubtitleStream]
}
