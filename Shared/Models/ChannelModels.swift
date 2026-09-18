import Foundation

/// A virtual channel as the Channels plugin reports it.
struct VirtualChannel: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let timeZoneId: String
    let daypartCount: Int

    enum CodingKeys: String, CodingKey {
        case id = "Id"
        case name = "Name"
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
}
