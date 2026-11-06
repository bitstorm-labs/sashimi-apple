import Foundation

extension BaseItemDto {
    /// The TMDB id from ProviderIds (present when the query asks for it).
    var tmdbId: Int? {
        guard let providerIds else { return nil }
        let value = providerIds.first { $0.key.caseInsensitiveCompare("Tmdb") == .orderedSame }?.value
        return value.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// Movie or show, in Seerr's terms. Nil for anything else.
    var seerrKind: SeerrMediaKind? {
        switch type {
        case .movie: return .movie
        case .series: return .tv
        default: return nil
        }
    }
}

/// Keeps search's "Not in your library" row to titles that aren't there:
/// anything Seerr says is on the server, or the library row already shows,
/// appears once, in the library row (mockup B).
enum SeerrSearchMerge {
    private struct Key: Hashable {
        let kind: SeerrMediaKind
        let tmdbId: Int
    }

    private struct TitleKey: Hashable {
        let kind: SeerrMediaKind
        let title: String
        let year: Int?
    }

    static func requestable(_ results: [SeerrSearchResult], library: [BaseItemDto]) -> [SeerrSearchResult] {
        var libraryIds = Set<Key>()
        var untaggedTitles = Set<TitleKey>()
        for item in library {
            guard let kind = item.seerrKind else { continue }
            if let tmdbId = item.tmdbId {
                libraryIds.insert(Key(kind: kind, tmdbId: tmdbId))
            } else {
                // No ProviderIds (an unmatched item): fall back to title and
                // year, which is only as good as the library's metadata.
                untaggedTitles.insert(TitleKey(kind: kind, title: normalized(item.name), year: item.productionYear))
            }
        }

        var seen = Set<Key>()
        return results.filter { result in
            let key = Key(kind: result.kind, tmdbId: result.tmdbId)
            guard seen.insert(key).inserted else { return false }
            if result.mediaInfo?.mediaStatus == .available { return false }
            if libraryIds.contains(key) { return false }
            let titleKey = TitleKey(kind: result.kind, title: normalized(result.title), year: result.year)
            return !untaggedTitles.contains(titleKey)
        }
    }

    /// Every movie and show once, in Seerr's order.
    static func unique(_ results: [SeerrSearchResult]) -> [SeerrSearchResult] {
        var seen = Set<Key>()
        return results.filter { seen.insert(Key(kind: $0.kind, tmdbId: $0.tmdbId)).inserted }
    }

    /// The library's copy of a Seerr title, by TMDB id only: a near-miss on
    /// title would open the wrong thing.
    static func libraryMatch(in items: [BaseItemDto], tmdbId: Int, kind: SeerrMediaKind) -> BaseItemDto? {
        items.first { $0.seerrKind == kind && $0.tmdbId == tmdbId }
    }

    private static func normalized(_ title: String) -> String {
        title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
