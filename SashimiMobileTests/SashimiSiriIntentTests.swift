import AppIntents
import Foundation
import XCTest
@testable import SashimiMobile

#if compiler(>=6.4)
@available(iOS 27.0, *)
#else
@available(iOS 17.2, *)
#endif
final class SashimiSiriIntentTests: XCTestCase {
    func testInAppSearchIntentRejectsBlankQueryBeforeSessionAccess() async {
        let intent = SashimiInAppSearchIntent()
        intent.criteria = StringSearchCriteria(term: " \n  ")

        do {
            _ = try await intent.perform()
            XCTFail("Expected a blank query to be rejected")
        } catch let error as SashimiSiriIntentError {
            XCTAssertEqual(error, .emptySearchQuery)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testIntentCoordinatorConsumesOnlyTheMatchingRoute() {
        let coordinator = SashimiIntentCoordinator()
        coordinator.requestSearch(query: "The Matrix")
        guard let route = coordinator.route else {
            return XCTFail("Expected a search route")
        }

        let unrelatedRoute = SashimiIntentCoordinator.Route.search(
            .init(id: UUID(), query: "Other title")
        )
        coordinator.consume(unrelatedRoute)
        XCTAssertEqual(coordinator.route, route)

        coordinator.consume(route)
        XCTAssertNil(coordinator.route)
    }

    @MainActor
    func testCanceledSearchAcknowledgementCannotConsumeAReplacementRequest() {
        let coordinator = SashimiIntentCoordinator()
        coordinator.requestSearch(query: "Old title")
        guard case .search(let oldRequest) = coordinator.route else {
            return XCTFail("Expected the original search route")
        }

        coordinator.requestSearch(query: "New title")
        guard case .search(let newRequest) = coordinator.route else {
            return XCTFail("Expected the replacement search route")
        }

        coordinator.consumeSearchRequest(id: oldRequest.id)
        XCTAssertEqual(coordinator.route, .search(newRequest))

        coordinator.consumeSearchRequest(id: newRequest.id)
        XCTAssertNil(coordinator.route)
    }

    @MainActor
    func testIntentCoordinatorRoutesPlayRequests() {
        let coordinator = SashimiIntentCoordinator()
        let entity = SashimiMediaEntity(
            id: "server:item",
            title: "The Office",
            serverID: "server",
            serverName: "Test Server",
            itemID: "item",
            mediaType: "Video",
            year: nil
        )

        coordinator.requestPlay(entity: entity)

        guard case .play(let request) = coordinator.route else {
            return XCTFail("Expected a play route")
        }
        XCTAssertEqual(request.entity, entity)

        coordinator.consume(coordinator.route!)
        XCTAssertNil(coordinator.route)
    }

    @MainActor
    func testPlaybackRouteStaysPendingUntilPlayerHandoffIsReady() {
        let coordinator = SashimiIntentCoordinator()
        let entity = SashimiMediaEntity(
            id: "server-ready:item-ready",
            title: "Ready Episode",
            serverID: "server-ready",
            serverName: "Ready Server",
            itemID: "item-ready",
            mediaType: "Episode",
            year: nil
        )

        coordinator.requestPlay(entity: entity)
        XCTAssertNotNil(coordinator.route)

        coordinator.acknowledgePlaybackReady(for: entity)
        XCTAssertNil(coordinator.route)
    }

    @MainActor
    func testFailedPlaybackHandoffOnlyConsumesTheMatchingRoute() {
        let coordinator = SashimiIntentCoordinator()
        let failedEntity = SashimiMediaEntity(
            id: "server-failed:item-failed",
            title: "Unavailable Episode",
            serverID: "server-failed",
            serverName: "Failed Server",
            itemID: "item-failed",
            mediaType: "Episode",
            year: nil
        )
        let replacementEntity = SashimiMediaEntity(
            id: "server-replacement:item-replacement",
            title: "Replacement Episode",
            serverID: "server-replacement",
            serverName: "Replacement Server",
            itemID: "item-replacement",
            mediaType: "Episode",
            year: nil
        )

        coordinator.requestPlay(entity: failedEntity)
        coordinator.requestPlay(entity: replacementEntity)
        coordinator.acknowledgePlaybackFailure(for: failedEntity)

        guard case .play(let request) = coordinator.route else {
            return XCTFail("The replacement route should remain pending")
        }
        XCTAssertEqual(request.entity, replacementEntity)
    }

    func testPlaybackTitleMatchingUsesExactNormalizedNames() {
        XCTAssertTrue(
            SashimiMediaPlaybackResolver.titleMatches(
                query: "the office",
                names: ["The Office"]
            )
        )
        XCTAssertTrue(
            SashimiMediaPlaybackResolver.titleMatches(
                query: "Beyoncé",
                names: ["Beyonce"]
            )
        )
        XCTAssertFalse(
            SashimiMediaPlaybackResolver.titleMatches(
                query: "The Office UK",
                names: ["The Office"]
            )
        )
    }

    func testPlaybackTitleMatchingIncludesSeriesNameForEpisodes() {
        XCTAssertTrue(
            SashimiMediaPlaybackResolver.titleMatches(
                query: "The Office",
                names: ["Pilot", "The Office"]
            )
        )
    }

    func testSearchQueryNormalizationRemovesCommonSiriWrappers() {
        let cases = [
            ("Search Sashimi for The Office", "The Office"),
            ("Search in the Sashimi app for The Office", "The Office"),
            ("Find The Office in Sashimi", "The Office"),
            ("Is The Office in Sashimi", "The Office"),
            ("Where can I watch The Office on Sashimi", "The Office"),
            ("The Office Sashimi", "The Office"),
            ("Play The Office in Sashimi", "The Office"),
            ("Resume The Office in Sashimi", "The Office")
        ]

        for (spokenPhrase, expectedTitle) in cases {
            XCTAssertEqual(
                SashimiMediaSearchQuery.normalizedTerm(spokenPhrase),
                expectedTitle,
                "Unexpected title for: \(spokenPhrase)"
            )
        }
    }

    func testSearchQueryClassifiesOpenAndLatestRequests() {
        XCTAssertTrue(SashimiMediaSearchQuery.isExplicitOpenRequest("Open DMV in Sashimi"))
        XCTAssertTrue(SashimiMediaSearchQuery.isExplicitOpenRequest("Go to Ghosts in Sashimi"))
        XCTAssertTrue(SashimiMediaSearchQuery.isExplicitOpenRequest("Show me Season 3 of Ghosts"))
        XCTAssertFalse(SashimiMediaSearchQuery.isExplicitOpenRequest("Search for Open Water in Sashimi"))
        XCTAssertFalse(SashimiMediaSearchQuery.isExplicitOpenRequest("Show me what's new in Sashimi"))

        XCTAssertTrue(SashimiMediaSearchQuery.isLatestAdditionsRequest("Show me latest additions in Sashimi"))
        XCTAssertTrue(SashimiMediaSearchQuery.isLatestAdditionsRequest("What's new in Sashimi"))
        XCTAssertFalse(SashimiMediaSearchQuery.isLatestAdditionsRequest("Open DMV in Sashimi"))
    }

    func testPlaybackRequestParsesTitleAndRequestedDestination() {
        let cases: [(String, String, SashimiPlaybackSelection)] = [
            ("Resume Ghosts in Sashimi", "Ghosts", .resume),
            ("Play the Up Next episode of Ghosts in Sashimi", "Ghosts", .upNext),
            ("Play Up Next for Ghosts in Sashimi", "Ghosts", .upNext),
            ("Play the newest episode of Ghosts in Sashimi", "Ghosts", .newestEpisode),
            ("Go to season two of Ghosts in Sashimi", "Ghosts", .season(number: 2)),
            ("Open the season 2 of Ghosts in Sashimi", "Ghosts", .season(number: 2)),
            ("Season 2 of Ghosts", "Ghosts", .season(number: 2)),
            ("Season two Ghosts", "Ghosts", .season(number: 2)),
            ("Is season two of Ghosts in Sashimi", "Ghosts", .season(number: 2)),
            ("Where can I watch season 2 of Ghosts in Sashimi", "Ghosts", .season(number: 2)),
            ("Ghosts season 2", "Ghosts", .season(number: 2)),
            ("Open Ghosts season 2 in Sashimi", "Ghosts", .season(number: 2)),
            ("Play Ghosts in Sashimi", "Ghosts", .automatic),
            ("Ghosts", "Ghosts", .automatic)
        ]

        for (spokenPhrase, expectedTitle, expectedSelection) in cases {
            let request = SashimiPlaybackRequest(rawTerm: spokenPhrase)
            XCTAssertEqual(request.title, expectedTitle, "Unexpected title for: \(spokenPhrase)")
            XCTAssertEqual(
                request.selection,
                expectedSelection,
                "Unexpected selection for: \(spokenPhrase)"
            )
            XCTAssertEqual(
                request.hasExplicitPlaybackDirective,
                spokenPhrase != "Ghosts",
                "Unexpected directive flag for: \(spokenPhrase)"
            )
        }
    }

    func testPlaybackRequestCanRecoverSystemSearchSeasonShorthand() {
        let request = SashimiPlaybackRequest(
            rawTerm: "Ghosts 2",
            allowSeasonShorthand: true
        )

        XCTAssertEqual(request.title, "Ghosts")
        XCTAssertEqual(request.selection, .season(number: 2))
        XCTAssertTrue(request.hasExplicitPlaybackDirective)
        XCTAssertTrue(request.isSeasonShorthand)

        let numberedTitle = SashimiPlaybackRequest(rawTerm: "Apollo 13")
        XCTAssertEqual(numberedTitle.title, "Apollo 13")
        XCTAssertEqual(numberedTitle.selection, .automatic)
        XCTAssertFalse(numberedTitle.isSeasonShorthand)
    }

#if compiler(>=6.4)
    @available(iOS 27.0, *)
    func testAppShortcutsExposeOpenLatestAndPlaybackActions() {
        // Search itself is supplied by the iOS 27 system.searchInApp schema;
        // predefined shortcuts are reserved for entity actions and latest
        // additions because AppShortcut parameter phrases accept AppEntity and
        // AppEnum parameters, not free-form String values.
        XCTAssertEqual(SashimiAppShortcuts.appShortcuts.count, 6)
    }

    @available(iOS 27.0, *)
    func testSearchStaysInSiriUntilOpenIntentIsSelected() {
        XCTAssertTrue(
            SashimiInAppSearchIntent.supportedModes.contains(.foreground(.dynamic))
        )
        XCTAssertFalse(
            SashimiInAppSearchIntent.supportedModes.contains(.foreground(.immediate))
        )
        XCTAssertTrue(SashimiTitleSearchIntent.supportedModes.contains(.background))
        XCTAssertTrue(
            SashimiOpenMediaIntent.supportedModes.contains(.foreground(.immediate))
        )
    }
#endif

    func testNewestEpisodeUsesPremiereDateThenEpisodeOrdering() {
        let episodes = [
            makeItem(
                id: "episode-one",
                name: "Episode One",
                type: .episode,
                indexNumber: 1,
                parentIndexNumber: 1,
                premiereDate: "2026-01-02T00:00:00Z"
            ),
            makeItem(
                id: "episode-two",
                name: "Episode Two",
                type: .episode,
                indexNumber: 2,
                parentIndexNumber: 1,
                premiereDate: "2026-01-02T00:00:00Z"
            ),
            makeItem(
                id: "episode-three",
                name: "Episode Three",
                type: .episode,
                indexNumber: 1,
                parentIndexNumber: 2,
                premiereDate: "2025-12-20T00:00:00Z"
            )
        ]

        XCTAssertEqual(
            SashimiMediaPlaybackResolver.newestEpisode(from: episodes)?.id,
            "episode-two"
        )
    }

    @MainActor
    func testIntentReadinessPreservesWarmActiveServer() async {
        let defaultServer = makeServer(id: "intent-default")
        let activeServer = makeServer(id: "intent-active")
        let manager = SessionManager(
            restoreOnLaunch: false,
            initialServers: [defaultServer, activeServer],
            initialActiveServerId: activeServer.id,
            initialDefaultServerId: defaultServer.id
        )

        await manager.restoreSessionForIntent()

        XCTAssertEqual(manager.activeServerId, activeServer.id)
        XCTAssertEqual(manager.defaultServerId, defaultServer.id)
    }

    @MainActor
    func testIntentReadinessWaitsForColdRestoreBeforeReportingSavedSession() async {
        let defaults = UserDefaults.standard
        let keys = ["servers", "activeServerId", "defaultServerId"]
        let previousValues = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previousValues) {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }

        let server = makeServer(id: "intent-cold")
        guard let data = try? JSONEncoder().encode([server]) else {
            return XCTFail("Could not encode the saved server")
        }
        defaults.set(data, forKey: "servers")
        defaults.set(server.id, forKey: "activeServerId")
        defaults.set(server.id, forKey: "defaultServerId")

        let manager = SessionManager(restoreOnLaunch: true)
        await manager.restoreSessionForIntent()

        XCTAssertEqual(manager.servers, [server])
        XCTAssertEqual(manager.activeServerId, server.id)
        XCTAssertEqual(manager.reauthServer, server)
        XCTAssertFalse(manager.isAuthenticated)
    }

    private func makeServer(id: String) -> ServerConfig {
        ServerConfig(
            id: id,
            name: id,
            url: URL(string: "https://\(id).invalid")!,
            username: "Intent Test User",
            userId: "user-\(id)"
        )
    }

    private func makeItem(
        id: String,
        name: String,
        type: ItemType,
        indexNumber: Int? = nil,
        parentIndexNumber: Int? = nil,
        premiereDate: String? = nil
    ) -> BaseItemDto {
        BaseItemDto(
            id: id,
            name: name,
            type: type,
            seriesName: "Ghosts",
            seriesId: "ghosts-series",
            seasonId: nil,
            parentId: nil,
            indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber,
            overview: nil,
            runTimeTicks: nil,
            userData: nil,
            imageTags: nil,
            backdropImageTags: nil,
            parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil,
            mediaType: nil,
            libraryName: nil,
            productionYear: nil,
            communityRating: nil,
            officialRating: nil,
            genres: nil,
            taglines: nil,
            people: nil,
            criticRating: nil,
            premiereDate: premiereDate,
            chapters: nil,
            path: nil,
            remoteTrailers: nil,
            localTrailerCount: nil,
            mediaStreams: nil
        )
    }
}
