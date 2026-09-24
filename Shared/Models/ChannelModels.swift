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
    /// The channel number the server assigned (plugin 0.7.0+): scattered,
    /// fixed, the same on every client. Absent from older servers.
    var number: Int?
    /// The logo key in effect today (plugin 0.8.0+); see `JellyfinClient.channelLogoURL`.
    var logo: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case description = "Description"
        case timeZoneId = "TimeZoneId"
        case daypartCount = "DaypartCount"
        case number = "Number"
        case logo = "Logo"
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

/// A channel's upcoming programmes, as the guide endpoint returns them.
struct ChannelGuide: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
    let programs: [GuideEntry]
    var number: Int?
    /// The logo key in effect today (plugin 0.8.0+).
    var logo: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
        case description = "Description"
        case programs = "Programs"
        case number = "Number"
        case logo = "Logo"
    }
}

struct GuideEntry: Codable, Identifiable, Equatable {
    let itemId: String
    let startUtc: Date
    let endUtc: Date

    /// How far into the item this airing already is. Non-zero only for the one
    /// in progress when the guide was fetched.
    let startPositionSeconds: Double

    // Filled by the server since plugin 0.4.0 so a week of guide does not
    // cost a request per programme. All optional: an older plugin omits them
    // and the guide falls back to fetching the item.
    let name: String?
    let type: String?
    let seriesName: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let productionYear: Int?
    /// Added to the library within the last week (plugin 0.6.0+).
    let isNew: Bool

    /// Airings repeat, so the item id alone is not unique within a guide.
    var id: String { "\(itemId)-\(startUtc.timeIntervalSince1970)" }

    var duration: TimeInterval { endUtc.timeIntervalSince(startUtc) }

    func isAiring(at date: Date) -> Bool { date >= startUtc && date < endUtc }

    enum CodingKeys: String, CodingKey {
        case itemId = "ItemId"
        case startUtc = "StartUtc"
        case endUtc = "EndUtc"
        case startPositionSeconds = "StartPositionSeconds"
        case name = "Name"
        case type = "Type"
        case seriesName = "SeriesName"
        case seasonNumber = "SeasonNumber"
        case episodeNumber = "EpisodeNumber"
        case productionYear = "ProductionYear"
        case isNew = "IsNew"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        itemId = try container.decode(String.self, forKey: .itemId)
        startPositionSeconds = try container.decode(Double.self, forKey: .startPositionSeconds)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        type = try container.decodeIfPresent(String.self, forKey: .type)
        seriesName = try container.decodeIfPresent(String.self, forKey: .seriesName)
        seasonNumber = try container.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try container.decodeIfPresent(Int.self, forKey: .episodeNumber)
        productionYear = try container.decodeIfPresent(Int.self, forKey: .productionYear)
        isNew = try container.decodeIfPresent(Bool.self, forKey: .isNew) ?? false
        // Same fractional-seconds trap as ChannelNowPlaying.
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
