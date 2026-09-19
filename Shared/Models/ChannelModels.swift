import Foundation

/// A virtual channel as the Channels plugin reports it.
struct VirtualChannel: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    /// What the channel is, which stays true as programmes change — distinct
    /// from the synopsis of whatever is currently airing.
    let description: String?
    let timeZoneId: String
    let daypartCount: Int

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case description = "Description"
        case timeZoneId = "TimeZoneId"
        case daypartCount = "DaypartCount"
    }
}

/// What a channel is airing, and where to join it.
struct ChannelNowPlaying: Codable, Equatable {
    let itemId: String

    /// How far into the item the broadcast already is.
    ///
    /// Not a resume position. The server documents it as join-in-progress and
    /// it must never be written back as playback progress — a channel advances
    /// whether or not anyone is watching, so reporting against it would record
    /// positions nobody actually reached.
    let startPositionSeconds: Double

    let startUtc: Date
    let endUtc: Date
    let nextItemId: String?

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case startPositionSeconds = "StartPositionSeconds"
        case startUtc = "StartUtc"
        case endUtc = "EndUtc"
        case nextItemId = "NextItemId"
    }

    init(
        itemId: String,
        startPositionSeconds: Double,
        startUtc: Date,
        endUtc: Date,
        nextItemId: String?
    ) {
        self.itemId = itemId
        self.startPositionSeconds = startPositionSeconds
        self.startUtc = startUtc
        self.endUtc = endUtc
        self.nextItemId = nextItemId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try container.decode(String.self, forKey: .itemId)
        startPositionSeconds = try container.decode(Double.self, forKey: .startPositionSeconds)
        nextItemId = try container.decodeIfPresent(String.self, forKey: .nextItemId)

        // Jellyfin serialises .NET DateTime with up to seven fractional digits
        // ("...:47.5249994Z"). JSONDecoder's .iso8601 strategy rejects any
        // fractional seconds at all, so it parsed only the occasional value
        // that happened to land on a whole second — which read as the countdown
        // "not working" rather than as an outright failure.
        startUtc = try Self.date(container, .startUtc)
        endUtc = try Self.date(container, .endUtc)
    }

    private static func date(
        _ container: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) throws -> Date {
        let raw = try container.decode(String.self, forKey: key)
        guard let parsed = DateFormatting.parseDate(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: container, debugDescription: "Unparseable date: \(raw)"
            )
        }
        return parsed
    }
}
