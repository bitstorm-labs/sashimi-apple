import AppIntents
import Foundation

// The resolver keeps the server fan-out, Jellyfin selection rules, and
// deterministic ranking together so every Siri/Shortcuts entry point shares
// exactly the same playback behavior.
// swiftlint:disable file_length type_body_length

/// The playback or navigation target expressed by a natural-language request.
/// Keeping this separate from App Intent types lets the same behavior serve
/// PlayVideoIntent, the in-app search fallback, and Shortcuts actions.
enum SashimiPlaybackSelection: Equatable, Sendable {
    case automatic
    case resume
    case upNext
    case newestEpisode
    case season(number: Int)
}

struct SashimiPlaybackRequest: Equatable, Sendable {
    let title: String
    let selection: SashimiPlaybackSelection
    let hasExplicitPlaybackDirective: Bool
    let isSeasonShorthand: Bool

    init(
        rawTerm: String,
        defaultSelection: SashimiPlaybackSelection = .automatic,
        allowSeasonShorthand: Bool = false
    ) {
        let collapsed = Self.collapseWhitespace(rawTerm)
        let explicitSeasonNumber = Self.seasonNumber(in: collapsed)
        let shorthandSeasonNumber = explicitSeasonNumber == nil && allowSeasonShorthand
            ? Self.trailingSeasonNumber(in: collapsed)
            : nil
        let seasonNumber = explicitSeasonNumber ?? shorthandSeasonNumber
        let lowercased = collapsed.lowercased()
        isSeasonShorthand = explicitSeasonNumber == nil && shorthandSeasonNumber != nil

        if let seasonNumber {
            selection = .season(number: seasonNumber)
            hasExplicitPlaybackDirective = true
        } else if Self.matches(lowercased, pattern: #"\b(?:up\s+next|next\s+episode)\b"#) {
            selection = .upNext
            hasExplicitPlaybackDirective = true
        } else if Self.matches(
            lowercased,
            pattern: #"\b(?:newest|latest|most\s+recent|recent)\s+episode\b"#
        ) {
            selection = .newestEpisode
            hasExplicitPlaybackDirective = true
        } else if Self.matches(
            lowercased,
            pattern: #"\b(?:resume|continue\s+watching|pick\s+up)\b"#
        ) {
            selection = .resume
            hasExplicitPlaybackDirective = true
        } else {
            selection = defaultSelection
            hasExplicitPlaybackDirective = Self.matches(
                lowercased,
                pattern: #"^\s*(?:please\s+)?(?:play|watch|start)\b"#
            )
        }

        title = Self.title(
            from: collapsed,
            removeTrailingSeasonNumber: isSeasonShorthand
        )
    }

    static func seasonRequest(title: String, number: Int) -> SashimiPlaybackRequest {
        SashimiPlaybackRequest(
            rawTerm: "Season \(number) of \(title)",
            defaultSelection: .season(number: number)
        )
    }

    private static func title(
        from rawValue: String,
        removeTrailingSeasonNumber: Bool = false
    ) -> String {
        var value = rawValue

        // Remove the command prefix before removing the more specific target
        // phrase. This handles both “play the newest episode of Ghosts” and
        // “go to season 2 of Ghosts”.
        value = replacing(
            value,
            pattern: #"^\s*(?:please\s+)?(?:go\s+to|open|show(?:\s+me)?|play|resume|watch|start|find|search(?:\s+for)?|is|are|can\s+i\s+(?:watch|see|find)|where\s+can\s+i\s+(?:watch|see)|what\s+can\s+i\s+watch|do\s+you\s+have)\s+"#
        )
        // Strip the app name before handling a target phrase at the end. For
        // example, “open Ghosts season 2 in Sashimi” should lose both the app
        // wrapper and the season suffix before the title is compared.
        value = replacing(
            value,
            pattern: #"\s+(?:in|on|from|using)\s+(?:the\s+)?sashimi(?:\s+app)?\s*$"#
        )
        value = replacing(
            value,
            pattern: #"\s+(?:the\s+)?sashimi(?:\s+app)?\s*$"#
        )
        value = replacing(
            value,
            pattern: #"^\s*(?:the\s+)?(?:up\s+next|next)(?:\s+episode)?\s+(?:of|for)\s+"#
        )
        value = replacing(
            value,
            pattern: #"^\s*(?:the\s+)?(?:newest|latest|most\s+recent|recent)\s+episode\s+(?:of|for)\s+"#
        )
        value = replacing(
            value,
            pattern: #"^\s*(?:the\s+)?season\s+(?:\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)(?:\s+(?:of|for))?\s+"#
        )

        // Also accept the target phrase after the title, as Siri may put the
        // spoken command into the term in either order.
        value = replacing(
            value,
            pattern: #"\s+(?:the\s+)?(?:up\s+next|next)(?:\s+episode)?(?:\s+(?:of|for))?\s*$"#
        )
        value = replacing(
            value,
            pattern: #"\s+(?:the\s+)?(?:newest|latest|most\s+recent|recent)\s+episode(?:\s+(?:of|for))?\s*$"#
        )
        value = replacing(
            value,
            pattern: #"\s+(?:the\s+)?season\s+(?:\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)(?:\s+(?:of|for))?\s*$"#
        )
        if removeTrailingSeasonNumber {
            value = replacing(
                value,
                pattern: #"\s+(?:\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\s*$"#
            )
        }

        return SashimiMediaSearchQuery.normalizedTerm(value)
    }

    private static func seasonNumber(in value: String) -> Int? {
        guard let match = firstMatch(
            value,
            pattern: #"\b(?:the\s+)?season\s+(\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\b"#
        ),
        let range = Range(match.range(at: 1), in: value) else {
            return nil
        }

        return number(from: String(value[range]))
    }

    private static func trailingSeasonNumber(in value: String) -> Int? {
        guard let match = firstMatch(
            value,
            pattern: #"\s(\d{1,3}|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty)\s*$"#
        ),
        let range = Range(match.range(at: 1), in: value) else {
            return nil
        }
        return number(from: String(value[range]))
    }

    private static func number(from component: String) -> Int? {
        let component = component.lowercased()
        if let number = Int(component) {
            return number
        }

        return [
            "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
            "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
            "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14,
            "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
            "nineteen": 19, "twenty": 20
        ][component]
    }

    private static func collapseWhitespace(_ value: String) -> String {
        value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        firstMatch(value, pattern: pattern) != nil
    }

    private static func firstMatch(_ value: String, pattern: String) -> NSTextCheckingResult? {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return nil
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.firstMatch(in: value, options: [], range: range)
    }

    private static func replacing(_ value: String, pattern: String) -> String {
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive]
        ) else {
            return value
        }
        let range = NSRange(value.startIndex..., in: value)
        return expression.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: ""
        )
    }
}

enum SashimiPlaybackDialog {
    static func make(
        for request: SashimiPlaybackRequest,
        entity: SashimiMediaEntity
    ) -> IntentDialog {
        switch request.selection {
        case .resume:
            return IntentDialog(
                full: "Resuming \(request.title) in Sashimi.",
                supporting: "Picking up from Continue Watching."
            )
        case .upNext:
            return IntentDialog(
                full: "Playing the next episode of \(request.title) in Sashimi.",
                supporting: "Now playing \(entity.title)."
            )
        case .newestEpisode:
            return IntentDialog(
                full: "Playing the newest episode of \(request.title) in Sashimi.",
                supporting: "Now playing \(entity.title)."
            )
        case .season(let number):
            return IntentDialog(
                full: "Opening Season \(number) of \(request.title) in Sashimi.",
                supporting: "Showing the episodes in that season."
            )
        case .automatic:
            return IntentDialog(
                full: "Playing \(request.title) in Sashimi.",
                supporting: "Now playing \(entity.title)."
            )
        }
    }
}

/// Resolves title requests against the saved servers without changing the
/// active server shown in the app chrome. Every returned entity retains its
/// server identity because Jellyfin item IDs are only meaningful on one
/// server.
enum SashimiMediaPlaybackResolver {
    struct Resolution: Sendable {
        let matches: [SashimiMediaEntity]
        let queriedServerCount: Int
        let failedServerCount: Int
    }

    private struct ServerConnection: Sendable {
        let id: String
        let name: String
        let url: URL
        let accessToken: String
        let userID: String
        let rank: Int
    }

    private struct Candidate: Sendable {
        let entity: SashimiMediaEntity
        let searchableNames: [String]
        let itemRank: Int
        let serverRank: Int
    }

    private struct ServerResponse: Sendable {
        let candidates: [Candidate]
        let succeeded: Bool
    }

    static func resolve(request: SashimiPlaybackRequest) async -> Resolution {
        guard !request.title.isEmpty else {
            return Resolution(matches: [], queriedServerCount: 0, failedServerCount: 0)
        }

        let connections = await serverConnections()
        let responses = await withTaskGroup(
            of: ServerResponse.self,
            returning: [ServerResponse].self
        ) { group in
            for connection in connections {
                group.addTask {
                    await fetchCandidates(from: connection, request: request)
                }
            }

            var responses: [ServerResponse] = []
            for await response in group {
                responses.append(response)
            }
            return responses
        }

        let candidates = responses
            .flatMap(\.candidates)
            .filter { candidate in
                titleMatches(query: request.title, names: candidate.searchableNames)
            }
            .sorted {
                if $0.serverRank != $1.serverRank {
                    return $0.serverRank < $1.serverRank
                }
                return $0.itemRank < $1.itemRank
            }

        return Resolution(
            matches: candidates.map(\.entity),
            queriedServerCount: responses.count,
            failedServerCount: responses.count(where: { !$0.succeeded })
        )
    }

    /// Resolves a title on the server already encoded in an AppEntity.
    /// Entity-based playback must stay server-local: the same Jellyfin item ID
    /// can refer to unrelated media on another saved server.
    static func resolve(
        request: SashimiPlaybackRequest,
        serverID: String
    ) async -> Resolution {
        guard !request.title.isEmpty else {
            return Resolution(matches: [], queriedServerCount: 0, failedServerCount: 0)
        }

        guard let connection = await serverConnections().first(where: { $0.id == serverID }) else {
            return Resolution(matches: [], queriedServerCount: 0, failedServerCount: 0)
        }

        let response = await fetchCandidates(from: connection, request: request)
        let candidates = response.candidates
            .filter { candidate in
                titleMatches(query: request.title, names: candidate.searchableNames)
            }
            .sorted { $0.itemRank < $1.itemRank }

        return Resolution(
            matches: candidates.map(\.entity),
            queriedServerCount: 1,
            failedServerCount: response.succeeded ? 0 : 1
        )
    }

    static func newestEpisode(from episodes: [BaseItemDto]) -> BaseItemDto? {
        episodes.reduce(nil) { newest, candidate in
            guard let newest else { return candidate }
            return isNewer(candidate, than: newest) ? candidate : newest
        }
    }

    static func seasonNumber(for season: BaseItemDto) -> Int? {
        if let indexNumber = season.indexNumber {
            return indexNumber
        }
        guard let match = try? NSRegularExpression(
            pattern: #"\bseason\s+(\d{1,3})\b"#,
            options: [.caseInsensitive]
        ).firstMatch(
            in: season.name,
            options: [],
            range: NSRange(season.name.startIndex..., in: season.name)
        ),
        let range = Range(match.range(at: 1), in: season.name) else {
            return nil
        }
        return Int(season.name[range])
    }

    static func titleMatches(query: String, names: [String]) -> Bool {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return false }
        return names.contains { normalize($0) == normalizedQuery }
    }

    @MainActor
    private static func serverConnections() -> [ServerConnection] {
        SessionManager.shared.servers.enumerated().compactMap { index, server in
            guard let accessToken = SessionManager.shared.token(
                for: server,
                allowLegacyFallback: true
            ) else {
                return nil
            }
            return ServerConnection(
                id: server.id,
                name: server.displayName,
                url: server.url,
                accessToken: accessToken,
                userID: server.userId,
                rank: serverPreferenceRank(for: server.id, savedIndex: index)
            )
        }
    }

    private static func fetchCandidates(
        from connection: ServerConnection,
        request: SashimiPlaybackRequest
    ) async -> ServerResponse {
        let client = JellyfinClient()
        await client.configure(
            serverURL: connection.url,
            accessToken: connection.accessToken,
            userId: connection.userID
        )

        do {
            let candidates: [Candidate]
            switch request.selection {
            case .resume:
                let items = try await client.getResumeItems(limit: 50)
                candidates = items.enumerated().map { index, item in
                    candidate(
                        item: item,
                        connection: connection,
                        names: [item.name, item.seriesName].compactMap { $0 },
                        rank: index
                    )
                }
            case .upNext:
                candidates = await resolveSeriesTargets(
                    client: client,
                    connection: connection,
                    title: request.title,
                    selection: .upNext
                )
            case .newestEpisode:
                candidates = await resolveSeriesTargets(
                    client: client,
                    connection: connection,
                    title: request.title,
                    selection: .newestEpisode
                )
            case .season(let number):
                candidates = await resolveSeriesTargets(
                    client: client,
                    connection: connection,
                    title: request.title,
                    selection: .season(number: number)
                )
            case .automatic:
                candidates = await resolveAutomaticTargets(
                    client: client,
                    connection: connection,
                    title: request.title
                )
            }
            return ServerResponse(candidates: candidates, succeeded: true)
        } catch is CancellationError {
            return ServerResponse(candidates: [], succeeded: false)
        } catch {
            return ServerResponse(candidates: [], succeeded: false)
        }
    }

    private static func resolveAutomaticTargets(
        client: JellyfinClient,
        connection: ServerConnection,
        title: String
    ) async -> [Candidate] {
        guard let results = try? await client.search(query: title, limit: 50) else {
            return []
        }

        let matchingResults = results.filter { result in
            titleMatches(query: title, names: [result.name, result.seriesName].compactMap { $0 })
        }

        let directItems = matchingResults.filter { $0.type?.isPlayableMediaType == true }
        if let directItem = directItems.first {
            return [candidate(
                item: directItem,
                connection: connection,
                names: [directItem.name, directItem.seriesName].compactMap { $0 },
                rank: 0
            )]
        }

        return await resolveSeriesTargets(
            client: client,
            connection: connection,
            title: title,
            selection: .automatic,
            matchingSeries: matchingResults.filter { $0.type == .series }
        )
    }

    private static func resolveSeriesTargets(
        client: JellyfinClient,
        connection: ServerConnection,
        title: String,
        selection: SashimiPlaybackSelection,
        matchingSeries suppliedSeries: [BaseItemDto]? = nil
    ) async -> [Candidate] {
        let series: [BaseItemDto]
        if let suppliedSeries {
            series = suppliedSeries
        } else if let results = try? await client.search(query: title, limit: 50) {
            series = results.filter { result in
                result.type == .series
                    && titleMatches(query: title, names: [result.name, result.seriesName].compactMap { $0 })
            }
        } else {
            return []
        }

        var candidates: [Candidate] = []
        for (seriesIndex, show) in series.enumerated() {
            switch selection {
            case .upNext:
                guard let episode = try? await client.getNextUp(seriesId: show.id, limit: 1).first else {
                    continue
                }
                candidates.append(candidate(
                    item: episode,
                    connection: connection,
                    names: [episode.name, episode.seriesName, show.name].compactMap { $0 },
                    rank: seriesIndex
                ))
            case .newestEpisode:
                guard let episodes = try? await client.getEpisodes(seriesId: show.id),
                      let episode = newestEpisode(from: episodes) else { continue }
                candidates.append(candidate(
                    item: episode,
                    connection: connection,
                    names: [episode.name, episode.seriesName, show.name].compactMap { $0 },
                    rank: seriesIndex
                ))
            case .season(let number):
                guard let seasons = try? await client.getSeasons(seriesId: show.id),
                      let season = seasons.first(where: { seasonNumber(for: $0) == number }) else {
                    continue
                }
                candidates.append(candidate(
                    item: season,
                    connection: connection,
                    names: [season.name, show.name].compactMap { $0 },
                    rank: seriesIndex
                ))
            case .automatic:
                guard let episode = await automaticEpisode(client: client, series: show) else {
                    continue
                }
                candidates.append(candidate(
                    item: episode,
                    connection: connection,
                    names: [episode.name, episode.seriesName, show.name].compactMap { $0 },
                    rank: seriesIndex
                ))
            case .resume:
                continue
            }
        }
        return candidates
    }

    private static func automaticEpisode(
        client: JellyfinClient,
        series: BaseItemDto
    ) async -> BaseItemDto? {
        // PlayVideoIntent may receive only the title even when the person said
        // “resume”. Prefer a matching Continue Watching item first so the
        // system video contract still picks up the saved playback position.
        if let resumed = try? await client.getResumeItems(limit: 50).first(where: {
            $0.seriesId == series.id
                || titleMatches(query: series.name, names: [$0.seriesName].compactMap { $0 })
        }) {
            return resumed
        }
        if let nextUp = try? await client.getNextUp(seriesId: series.id, limit: 1).first {
            return nextUp
        }
        if let unwatched = try? await client.getItems(
            parentId: series.id,
            includeTypes: [.episode],
            sortBy: "ParentIndexNumber,IndexNumber",
            limit: 1,
            isPlayed: false
        ).items.first {
            return unwatched
        }
        return try? await client.getEpisodes(seriesId: series.id).first
    }

    private static func candidate(
        item: BaseItemDto,
        connection: ServerConnection,
        names: [String],
        rank: Int
    ) -> Candidate {
        Candidate(
            entity: SashimiMediaEntity(
                item: item,
                serverID: connection.id,
                serverName: connection.name
            ),
            searchableNames: names,
            itemRank: rank,
            serverRank: connection.rank
        )
    }

    private static func isNewer(_ candidate: BaseItemDto, than current: BaseItemDto) -> Bool {
        let candidateDate = parseDate(candidate.premiereDate)
        let currentDate = parseDate(current.premiereDate)
        if let candidateDate, let currentDate, candidateDate != currentDate {
            return candidateDate > currentDate
        }
        if candidateDate != nil, currentDate == nil {
            return true
        }
        if candidateDate == nil, currentDate != nil {
            return false
        }

        let candidateSeason = candidate.parentIndexNumber ?? -1
        let currentSeason = current.parentIndexNumber ?? -1
        if candidateSeason != currentSeason {
            return candidateSeason > currentSeason
        }

        let candidateEpisode = candidate.indexNumber ?? -1
        let currentEpisode = current.indexNumber ?? -1
        if candidateEpisode != currentEpisode {
            return candidateEpisode > currentEpisode
        }
        return candidate.name.localizedStandardCompare(current.name) == .orderedDescending
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(
                options: [.diacriticInsensitive, .caseInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .filter { $0.isLetter || $0.isNumber }
    }

    @MainActor
    private static func serverPreferenceRank(for id: String, savedIndex: Int) -> Int {
        let activeID = SessionManager.shared.activeServerId
        let defaultID = SessionManager.shared.defaultServerId
        if id == activeID { return 0 }
        if id == defaultID { return 1 }
        return savedIndex + 2
    }
}
