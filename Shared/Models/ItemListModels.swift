import Foundation

/// `GET /Playlists/{id}`: who may see a list and who it is shared with.
/// `itemIds` is NOT filtered by the viewer's parental limits, so nothing that
/// a viewer sees (counts, "new") may be derived from it.
struct PlaylistSharing: Decodable, Equatable {
    let openAccess: Bool
    let shares: [PlaylistShare]
    let itemIds: [String]

    enum CodingKeys: String, CodingKey {
        case openAccess = "OpenAccess"
        case shares = "Shares"
        case itemIds = "ItemIds"
    }

    init(openAccess: Bool, shares: [PlaylistShare], itemIds: [String] = []) {
        self.openAccess = openAccess
        self.shares = shares
        self.itemIds = itemIds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openAccess = try container.decodeIfPresent(Bool.self, forKey: .openAccess) ?? false
        shares = try container.decodeIfPresent([PlaylistShare].self, forKey: .shares) ?? []
        itemIds = try container.decodeIfPresent([String].self, forKey: .itemIds) ?? []
    }
}

/// `POST /Playlists` answers with the new playlist's id.
struct PlaylistCreationResult: Decodable {
    let id: String

    enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

/// `{ Items, TotalRecordCount }`, the shape of most item listings.
struct ItemsResponse: Codable {
    let items: [BaseItemDto]
    let totalRecordCount: Int

    enum CodingKeys: String, CodingKey {
        case items = "Items"
        case totalRecordCount = "TotalRecordCount"
    }
}

/// A list of items whose `TotalRecordCount` may be absent (playlist listings).
struct LooseItemsResponse: Decodable {
    let items: [BaseItemDto]

    enum CodingKeys: String, CodingKey {
        case items = "Items"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([BaseItemDto].self, forKey: .items) ?? []
    }
}
