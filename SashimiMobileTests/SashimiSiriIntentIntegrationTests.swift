import AppIntents
import XCTest
@testable import SashimiMobile

#if compiler(>=6.4)
/// Opt-in live coverage for the App Intent execution path on a paired device.
///
/// These tests deliberately call the production intents with the same natural
/// language strings a person gives Siri. They are skipped by default because
/// CI and simulators do not have the user's saved Jellyfin credentials. Enable
/// them only on an authenticated device with:
/// `SASHIMI_RUN_LIVE_INT_TESTS=1 xcodebuild test ...`
@available(iOS 27.0, *)
final class SashimiSiriIntentIntegrationTests: XCTestCase {
    func testTypedSearchPhrasesReturnLiveCards() async throws {
        try await requireLiveSession()

        let phrases = [
            "Search Sashimi for Ghosts",
            "Search in the Sashimi app for Ghosts",
            "Is Ghosts in Sashimi"
        ]

        for phrase in phrases {
            var intent = SashimiTitleSearchIntent()
            intent.searchTerm = phrase

            let result = try await intent.perform()
            let entities = try XCTUnwrap(result.value, "No card value for: \(phrase)")
            XCTAssertFalse(entities.isEmpty, "No live cards for: \(phrase)")
            XCTAssertTrue(
                entities.contains { $0.title.localizedCaseInsensitiveContains("Ghosts") },
                "Ghosts was not returned for: \(phrase)"
            )
        }
    }

    func testTypedLatestAdditionsPhraseReturnsDefaultServerCards() async throws {
        try await requireLiveSession()

        let phrases = [
            "Show me latest additions in Sashimi",
            "What's new in Sashimi"
        ]
        let defaultServerID = await MainActor.run { SessionManager.shared.defaultServer?.id }

        for phrase in phrases {
            var intent = SashimiInAppSearchIntent()
            intent.criteria = StringSearchCriteria(term: phrase)

            let result = try await intent.perform()
            let entities = try XCTUnwrap(result.value, "Latest additions returned no value: \(phrase)")

            XCTAssertFalse(entities.isEmpty, "The default server returned no latest additions: \(phrase)")
            XCTAssertTrue(
                entities.allSatisfy { $0.serverID == defaultServerID },
                "Latest additions crossed the default-server boundary: \(phrase)"
            )
        }
    }

    @MainActor
    func testTypedResumePhraseRoutesAContinueWatchingItem() async throws {
        try await requireLiveSession()

        let title = try await firstLiveResumeTitle()
        var intent = SashimiPlayVideoIntent()
        intent.term = "Resume \(title) in Sashimi"

        _ = try await intent.perform()

        guard case .play(let request) = SashimiIntentCoordinator.shared.lastRequestedRoute else {
            return XCTFail(
                "Resume phrase did not create a play route: \(String(describing: SashimiIntentCoordinator.shared.lastRequestedRoute))"
            )
        }
        XCTAssertEqual(
            request.entity.mediaType,
            ItemType.episode.rawValue,
            "Resume should route a Continue Watching episode, not the series shell"
        )
        XCTAssertFalse(request.entity.itemID.isEmpty)
        SashimiIntentCoordinator.shared.consume(.play(request))
    }

    @MainActor
    func testTypedSeasonPhraseRoutesASeasonPage() async throws {
        try await requireLiveSession()

        var intent = SashimiPlayVideoIntent()
        intent.term = "Open season 3 of Ghosts in Sashimi"

        _ = try await intent.perform()

        guard case .open(let request) = SashimiIntentCoordinator.shared.lastRequestedRoute else {
            return XCTFail("Season phrase did not create an open route")
        }
        XCTAssertTrue(request.entity.title.localizedCaseInsensitiveContains("Season 3"))
        SashimiIntentCoordinator.shared.consume(.open(request))
    }

    @MainActor
    func testTypedOpenPhraseLeavesNavigationToOpenIntent() async throws {
        try await requireLiveSession()
        let openIntent = try await performOpenPhrase("Open Ghosts in Sashimi")

        XCTAssertNil(
            SashimiIntentCoordinator.shared.route,
            "The search intent should return an OpenIntent instead of routing directly"
        )
        XCTAssertTrue(openIntent.target.title.localizedCaseInsensitiveContains("Ghosts"))

        _ = try await openIntent.perform()
        consumeOpenRoute(for: openIntent.target)
    }

    @MainActor
    func testTypedSeasonPhraseLeavesNavigationToOpenIntent() async throws {
        try await requireLiveSession()
        let openIntent = try await performOpenPhrase("Open season 3 of Ghosts in Sashimi")

        XCTAssertNil(
            SashimiIntentCoordinator.shared.route,
            "The season search intent should return an OpenIntent instead of routing directly"
        )
        XCTAssertTrue(openIntent.target.title.localizedCaseInsensitiveContains("Season 3"))

        _ = try await openIntent.perform()
        consumeOpenRoute(for: openIntent.target)
    }

    @MainActor
    func testCardOpenIntentRoutesTheResolvedTitle() async throws {
        try await requireLiveSession()
        clearPendingRoute()

        var searchIntent = SashimiTitleSearchIntent()
        searchIntent.searchTerm = "Ghosts"
        let searchResult = try await searchIntent.perform()
        let entity = try XCTUnwrap(
            searchResult.value?.first(where: { $0.title.localizedCaseInsensitiveContains("Ghosts") })
        )

        _ = try await SashimiOpenMediaIntent(target: entity).perform()

        guard case .open(let request) = SashimiIntentCoordinator.shared.route else {
            return XCTFail("The card's OpenIntent did not create an open route")
        }
        XCTAssertEqual(request.entity, entity)
        SashimiIntentCoordinator.shared.consume(.open(request))
    }

    @MainActor
    private func performOpenPhrase(_ phrase: String) async throws -> SashimiOpenMediaIntent {
        clearPendingRoute()
        let recorder = OpenIntentRecorder()

        let result = try await SashimiSiriIntentDependencies.$openIntentFactory.withValue(
            { entity in recorder.makeIntent(for: entity) },
            operation: {
                var intent = SashimiInAppSearchIntent()
                intent.criteria = StringSearchCriteria(term: phrase)
                try await intent.perform()
            }
        )
        assertOpenHandoff(result)
        return try XCTUnwrap(recorder.intent)
    }

    @MainActor
    private func consumeOpenRoute(for entity: SashimiMediaEntity) {
        guard case .open(let request) = SashimiIntentCoordinator.shared.route else {
            XCTFail("The returned OpenIntent did not create an open route")
            return
        }
        XCTAssertEqual(request.entity, entity)
        SashimiIntentCoordinator.shared.consume(.open(request))
    }

    private func assertOpenHandoff<Result: OpensIntent>(_ result: Result) {
        XCTAssertTrue(result is any OpensIntent)
    }

    @MainActor
    private func clearPendingRoute() {
        if let route = SashimiIntentCoordinator.shared.route {
            SashimiIntentCoordinator.shared.consume(route)
        }
    }

    private func requireLiveSession() async throws {
        #if !SASHIMI_LIVE_INT_TESTS
        let processInfo = ProcessInfo.processInfo
        let isEnabled = processInfo.environment["SASHIMI_RUN_LIVE_INT_TESTS"] == "1"
            || processInfo.arguments.contains("--sashimi-run-live-int-tests")
            guard isEnabled else {
                throw XCTSkip("Set SASHIMI_RUN_LIVE_INT_TESTS=1 on an authenticated device")
            }
        #endif

        await SessionManager.shared.restoreSessionForIntent()
        let state = await MainActor.run {
            (
                isAuthenticated: SessionManager.shared.isAuthenticated,
                isConnected: NetworkMonitor.shared.isConnected,
                hasSavedServers: !SessionManager.shared.servers.isEmpty
            )
        }
        guard state.hasSavedServers, state.isAuthenticated, state.isConnected else {
            throw XCTSkip("Duoro has no authenticated, connected Sashimi session")
        }
    }

    private func firstLiveResumeTitle() async throws -> String {
        let servers = await MainActor.run {
            SessionManager.shared.servers.map { ($0.id, $0.url, $0.userId) }
        }

        for (serverID, serverURL, userID) in servers {
            let token: String? = await MainActor.run {
                guard let server = SessionManager.shared.servers.first(where: { $0.id == serverID }) else {
                    return nil
                }
                return SessionManager.shared.token(for: server, allowLegacyFallback: true)
            }
            guard let token else { continue }

            let client = JellyfinClient()
            await client.configure(
                serverURL: serverURL,
                accessToken: token,
                userId: userID
            )
            guard let item = (try? await client.getResumeItems(limit: 50))?.first else {
                continue
            }
            return item.seriesName ?? item.name
        }

        throw XCTSkip("No live Continue Watching item is available on Duoro")
    }
}

private final class OpenIntentRecorder: @unchecked Sendable {
    private(set) var intent: SashimiOpenMediaIntent?

    func makeIntent(for entity: SashimiMediaEntity) -> SashimiOpenMediaIntent {
        let intent = SashimiOpenMediaIntent(target: entity)
        self.intent = intent
        return intent
    }
}
#endif
