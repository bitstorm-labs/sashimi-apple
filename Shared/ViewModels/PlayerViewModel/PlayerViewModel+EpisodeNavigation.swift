import Foundation
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "PlayerViewModel")

extension PlayerViewModel {
    /// Starts or refreshes navigation for the current episode. A non-episode
    /// deliberately becomes `.notApplicable`, so movies and standalone videos
    /// never acquire episode controls by accident.
    func refreshEpisodeNavigation() async {
        guard let item = currentItem else { return }
        transitionState.currentItem = item
        await refreshEpisodeNavigation(for: item)
    }

    func startNavigationLookup(for item: BaseItemDto) {
        navigationTask?.cancel()
        transitionState.previousEpisode = nil
        transitionState.nextEpisode = nil
        transitionState.endCard = nil
        guard item.type == .episode, !isOfflinePlayback || offlineEpisodeSource != nil else {
            transitionState.lookupStatus = .notApplicable
            return
        }
        transitionState.lookupStatus = .loading
        navigationTask = Task { [weak self] in
            await self?.refreshEpisodeNavigation(for: item)
        }
    }

    private func refreshEpisodeNavigation(for item: BaseItemDto) async {
        guard item.type == .episode else {
            transitionState.lookupStatus = .notApplicable
            return
        }
        if isOfflinePlayback {
            refreshOfflineEpisodeNavigation(for: item)
            return
        }
        guard let seasonId = item.seasonId, let currentIndex = item.indexNumber else {
            transitionState.lookupStatus = .unavailable
            return
        }

        do {
            let response = try await navigationClient.getPlayerItems(
                parentId: seasonId,
                includeTypes: [.episode],
                sortBy: "IndexNumber",
                limit: 100
            )
            guard currentItem?.id == item.id else { return }

            let episodes = response.items.sorted(by: episodeComesBefore)
            var previous = episodes.last {
                guard let index = $0.indexNumber else { return false }
                return index < currentIndex
            }
            var next = Self.episode(after: currentIndex, in: episodes)

            // A season boundary is part of the same ordered series as an
            // in-season transition. Resolve both directions from the server's
            // season order so season numbers may contain gaps and the first
            // episode of season 2 still exposes the final episode of season 1.
            if previous == nil {
                previous = try await fetchLastEpisodeOfPreviousSeason(for: item)
            }
            if next == nil {
                next = try await fetchFirstEpisodeOfNextSeason(for: item)
            }
            guard currentItem?.id == item.id else { return }
            transitionState.previousEpisode = previous
            transitionState.nextEpisode = next
            transitionState.lookupStatus = (previous != nil || next != nil) ? .available : .unavailable
            diag(.navigationLookup, [
                PlayerDiagnostics.field("item", item.id),
                PlayerDiagnostics.field("previous", previous?.id),
                PlayerDiagnostics.field("next", next?.id),
                PlayerDiagnostics.field("outcome", next == nil ? "no-successor" : "available")
            ])
        } catch is CancellationError {
            return
        } catch {
            guard currentItem?.id == item.id else { return }
            transitionState.lookupStatus = .failed
            diagFailure(.navigationLookup, [
                PlayerDiagnostics.field("item", item.id),
                PlayerDiagnostics.field("outcome", "request-failed")
            ] + PlayerDiagnostics.fields(for: error))
        }
    }

    /// Local-file playback navigates among the downloads: no server, and only
    /// episodes that can actually play from here.
    private func refreshOfflineEpisodeNavigation(for item: BaseItemDto) {
        guard let offlineEpisodeSource else {
            transitionState.lookupStatus = .notApplicable
            return
        }
        let adjacent = offlineEpisodeSource.adjacentEpisodes(to: item)
        guard currentItem?.id == item.id else { return }
        transitionState.previousEpisode = adjacent.previous
        transitionState.nextEpisode = adjacent.next
        transitionState.lookupStatus = (adjacent.previous != nil || adjacent.next != nil) ? .available : .unavailable
        diag(.navigationLookup, [
            PlayerDiagnostics.field("item", item.id),
            PlayerDiagnostics.field("previous", adjacent.previous?.id),
            PlayerDiagnostics.field("next", adjacent.next?.id),
            PlayerDiagnostics.field("offline", true),
            PlayerDiagnostics.field("outcome", adjacent.next == nil ? "no-successor" : "available")
        ])
    }

    private static func episode(after index: Int, in episodes: [BaseItemDto]) -> BaseItemDto? {
        episodes.first {
            guard let candidate = $0.indexNumber else { return false }
            return candidate > index
        }
    }

    /// The episode after `item` in series order, resolved the same way as the
    /// player's Next (in-season, then the next non-empty season). The Up Next
    /// screen's Skip uses it to look past the episode it is showing; offline,
    /// only downloaded episodes count.
    func episodeFollowing(_ item: BaseItemDto) async throws -> BaseItemDto? {
        if isOfflinePlayback {
            return offlineEpisodeSource?.adjacentEpisodes(to: item).next
        }
        guard let seasonId = item.seasonId, let currentIndex = item.indexNumber else { return nil }
        if let next = Self.episode(after: currentIndex, in: try await episodes(in: seasonId)) {
            return next
        }
        return try await fetchFirstEpisodeOfNextSeason(for: item)
    }

    func waitForEpisodeNavigation(for item: BaseItemDto) async {
        guard currentItem?.id == item.id else { return }
        if transitionState.lookupStatus == .loading {
            await navigationTask?.value
        }
        if transitionState.lookupStatus == .idle {
            await refreshEpisodeNavigation(for: item)
        }
    }

    private func episodeComesBefore(_ lhs: BaseItemDto, _ rhs: BaseItemDto) -> Bool {
        let lhsIndex = lhs.indexNumber ?? Int.max
        let rhsIndex = rhs.indexNumber ?? Int.max
        return lhsIndex == rhsIndex ? lhs.id < rhs.id : lhsIndex < rhsIndex
    }

    private func seasonComesBefore(_ lhs: BaseItemDto, _ rhs: BaseItemDto) -> Bool {
        let lhsIndex = lhs.indexNumber ?? Int.max
        let rhsIndex = rhs.indexNumber ?? Int.max
        return lhsIndex == rhsIndex ? lhs.id < rhs.id : lhsIndex < rhsIndex
    }

    private func orderedSeasons(for seriesId: String) async throws -> [BaseItemDto] {
        let response = try await navigationClient.getPlayerItems(
            parentId: seriesId,
            includeTypes: [.season],
            sortBy: "IndexNumber",
            limit: 100
        )
        return response.items.sorted(by: seasonComesBefore)
    }

    private func episodes(in seasonId: String) async throws -> [BaseItemDto] {
        let response = try await navigationClient.getPlayerItems(
            parentId: seasonId,
            includeTypes: [.episode],
            sortBy: "IndexNumber",
            limit: 100
        )
        return response.items.sorted(by: episodeComesBefore)
    }

    /// After a season finale, find the first episode in the next non-empty
    /// season so autoplay and manual Next roll over across season gaps.
    private func fetchFirstEpisodeOfNextSeason(for item: BaseItemDto) async throws -> BaseItemDto? {
        guard let seriesId = item.seriesId,
              let seasonId = item.seasonId else { return nil }
        let seasons = try await orderedSeasons(for: seriesId)
        guard let currentPosition = seasonPosition(
            seasonId: seasonId,
            seasonNumber: item.parentIndexNumber,
            in: seasons
        ) else {
            return nil
        }
        for season in seasons.dropFirst(currentPosition + 1) {
            let seasonEpisodes = try await episodes(in: season.id)
            if let first = firstRegularEpisode(in: seasonEpisodes) {
                return first
            }
        }
        return nil
    }

    func firstRegularEpisode(in episodes: [BaseItemDto]) -> BaseItemDto? {
        episodes.first { ($0.indexNumber ?? 0) >= 1 } ?? episodes.first
    }

    /// Before a season premiere, find the last episode in the previous
    /// non-empty season so Previous remains a complete series-order action.
    private func fetchLastEpisodeOfPreviousSeason(for item: BaseItemDto) async throws -> BaseItemDto? {
        guard let seriesId = item.seriesId,
              let seasonId = item.seasonId else { return nil }
        let seasons = try await orderedSeasons(for: seriesId)
        guard let currentPosition = seasonPosition(
            seasonId: seasonId,
            seasonNumber: item.parentIndexNumber,
            in: seasons
        ) else {
            return nil
        }
        for season in seasons.prefix(currentPosition).reversed() {
            if let last = try await episodes(in: season.id).last {
                return last
            }
        }
        return nil
    }

    private func seasonPosition(
        seasonId: String,
        seasonNumber: Int?,
        in seasons: [BaseItemDto]
    ) -> Int? {
        if let position = seasons.firstIndex(where: { $0.id == seasonId }) {
            return position
        }
        guard let seasonNumber else { return nil }
        return seasons.firstIndex { $0.indexNumber == seasonNumber }
    }

    /// Standalone videos historically auto-advanced using their parent folder
    /// ordering. Keep that behavior private to the completion path: videos
    /// are not episodes and must not acquire episode navigation controls.
    func fetchNextVideo(for item: BaseItemDto) async -> BaseItemDto? {
        guard let parentId = item.seasonId ?? item.seriesId ?? item.parentId,
              let currentIndex = item.indexNumber else { return nil }
        do {
            let response = try await client.getItems(
                parentId: parentId,
                includeTypes: [.video],
                sortBy: "IndexNumber",
                limit: 100
            )
            return response.items
                .sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
                .first { ($0.indexNumber ?? 0) > currentIndex }
        } catch {
            // Auto-advance just stops here; log so a failing lookup is not
            // indistinguishable from "this was the last video".
            logger.error("Next-video lookup failed for \(item.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
