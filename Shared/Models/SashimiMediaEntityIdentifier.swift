import Foundation

/// A stable identity for a media item within a saved Sashimi server.
/// Jellyfin item IDs are server-scoped, so neither ID is sufficient alone.
struct SashimiMediaEntityIdentifier: Hashable, Sendable {
    let serverID: String
    let itemID: String

    /// Length-prefix the server ID so either component can contain punctuation
    /// without making the identifier ambiguous.
    var rawValue: String {
        "\(serverID.count):\(serverID)\(itemID)"
    }

    init(serverID: String, itemID: String) {
        self.serverID = serverID
        self.itemID = itemID
    }

    init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":"),
              let serverLength = Int(rawValue[..<separator]),
              serverLength > 0 else {
            return nil
        }

        let serverStart = rawValue.index(after: separator)
        guard let serverEnd = rawValue.index(
            serverStart,
            offsetBy: serverLength,
            limitedBy: rawValue.endIndex
        ), serverEnd < rawValue.endIndex else {
            return nil
        }

        let serverID = String(rawValue[serverStart..<serverEnd])
        let itemID = String(rawValue[serverEnd...])
        guard !serverID.isEmpty, !itemID.isEmpty else { return nil }

        self.init(serverID: serverID, itemID: itemID)
    }
}
