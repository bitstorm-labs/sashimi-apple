import Foundation

/// A media item together with the saved Jellyfin server that returned it.
/// Item IDs are only meaningful within a server, so the server ID is part of
/// the identity everywhere search results are rendered or opened.
struct ServerMediaResult: Identifiable, Hashable {
    let item: BaseItemDto
    let serverID: String
    let serverName: String
    let serverURL: URL

    var id: String {
        "\(serverID):\(item.id)"
    }
}

/// One deduplicated title with one source per saved server.
struct ServerMediaResultGroup: Identifiable {
    let id: String
    let sources: [ServerMediaResult]

    var primary: ServerMediaResult {
        sources[0]
    }
}

enum ServerMediaResultGrouping {
    /// Deduplicates by title, year, and media type while preserving the server
    /// sources. If a single server has duplicate library entries, retain the
    /// best-quality copy as that server's source for the compact search card.
    static func groups(
        from results: [ServerMediaResult],
        preferredServerID: String? = nil
    ) -> [ServerMediaResultGroup] {
        var keyOrder: [String] = []
        var buckets: [String: [ServerMediaResult]] = [:]

        for result in results {
            let key = canonicalKey(for: result.item)
            if buckets[key] == nil {
                keyOrder.append(key)
            }
            buckets[key, default: []].append(result)
        }

        return keyOrder.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            var bestByServer: [String: ServerMediaResult] = [:]
            for result in bucket {
                if let current = bestByServer[result.serverID] {
                    if isBetter(result, than: current) {
                        bestByServer[result.serverID] = result
                    }
                } else {
                    bestByServer[result.serverID] = result
                }
            }
            let sources = bestByServer.values.sorted {
                if let preferredServerID {
                    if $0.serverID == preferredServerID, $1.serverID != preferredServerID {
                        return true
                    }
                    if $1.serverID == preferredServerID, $0.serverID != preferredServerID {
                        return false
                    }
                }
                return $0.serverName.localizedCaseInsensitiveCompare($1.serverName) == .orderedAscending
            }
            guard !sources.isEmpty else { return nil }
            return ServerMediaResultGroup(id: key, sources: sources)
        }
    }

    private static func canonicalKey(for item: BaseItemDto) -> String {
        let title = item.name
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber }
        let year = item.displayYear.map(String.init) ?? ""
        let type = item.type?.rawValue ?? "Unknown"
        return "\(type)|\(year)|\(title)"
    }

    private static func isBetter(_ candidate: ServerMediaResult, than current: ServerMediaResult) -> Bool {
        let candidateQuality = qualityRank(candidate.item.qualityBadge)
        let currentQuality = qualityRank(current.item.qualityBadge)
        if candidateQuality != currentQuality {
            return candidateQuality > currentQuality
        }
        let candidateRating = candidate.item.communityRating ?? 0
        let currentRating = current.item.communityRating ?? 0
        if candidateRating != currentRating {
            return candidateRating > currentRating
        }
        return candidate.item.id.localizedStandardCompare(current.item.id) == .orderedAscending
    }

    private static func qualityRank(_ quality: String?) -> Int {
        switch quality {
        case "4K": return 3
        case "HD": return 2
        case "SD": return 1
        default: return 0
        }
    }
}
