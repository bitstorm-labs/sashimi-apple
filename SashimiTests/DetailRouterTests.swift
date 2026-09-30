import XCTest
@testable import Sashimi

/// `DetailRouter` is the tvOS navigation path for detail pages (issue #15).
/// These pin the three things it owns beyond push/pop: which show's theme
/// plays, how long another server's client scope lives, and deep-link hand-off.
@MainActor
final class DetailRouterTests: XCTestCase {
    /// Scripted server-scope service: records begins/ends, and lets a test
    /// hold a begin open to observe the "connecting" state.
    private final class ScopeService {
        var begins: [String] = []
        var ends: [ServerClientScopeToken] = []
        var tokens: [String: ServerClientScopeToken] = [:]
        var failServers: Set<String> = []
        var holdBegins = false
        private var held: [CheckedContinuation<Void, Never>] = []

        func begin(_ serverID: String) async -> ServerClientScopeToken? {
            begins.append(serverID)
            if holdBegins {
                await withCheckedContinuation { held.append($0) }
            }
            guard !failServers.contains(serverID) else { return nil }
            let token = ServerClientScopeToken()
            tokens[serverID] = token
            return token
        }

        func end(_ token: ServerClientScopeToken) async {
            ends.append(token)
        }

        func release() {
            let pending = held
            held = []
            pending.forEach { $0.resume() }
        }
    }

    private var scopes: ScopeService!
    private var themes: [String?]!
    private var router: DetailRouter!

    override func setUp() async throws {
        scopes = ScopeService()
        themes = []
        let scopes = scopes!
        router = DetailRouter(
            beginScope: { await scopes.begin($0) },
            endScope: { await scopes.end($0) },
            themeSeriesChanged: { [unowned self] in self.themes.append($0) }
        )
    }

    // MARK: - Path

    func testPushPopAndRoot() {
        XCTAssertTrue(router.isAtRoot)
        router.push(.item(item("s1", .series)))
        router.push(.item(item("e1", .episode, series: "s1")))
        XCTAssertEqual(router.path.count, 2)
        XCTAssertFalse(router.isAtRoot)

        router.pop()
        XCTAssertEqual(router.path.map(\.destination), [.item(item("s1", .series))])

        router.popToRoot()
        XCTAssertTrue(router.isAtRoot)
        router.pop() // popping an empty path is a no-op, not a crash
        XCTAssertTrue(router.isAtRoot)
    }

    func testPushingTheSameTitleTwiceMakesTwoDistinctPages() {
        // Episode -> Series -> the same Episode again: NavigationStack needs
        // distinct values, and per-page state is keyed on the page.
        let episode = item("e1", .episode, series: "s1")
        router.push(.item(episode))
        router.push(.item(item("s1", .series)))
        router.push(.item(episode))
        XCTAssertEqual(Set(router.path.map(\.id)).count, 3)
        XCTAssertNotEqual(router.path[0], router.path[2])
    }

    func testOpenExternallyIsAHandOffNotAPush() {
        router.push(.item(item("m1", .movie)))
        router.openExternally(.item(item("m2", .movie)))
        // The tab host decides where it lands (it may need a tab switch
        // first); the router only publishes the request.
        XCTAssertEqual(router.externalRequest?.destination, .item(item("m2", .movie)))
        XCTAssertEqual(router.path.count, 1)
    }

    // MARK: - Theme songs

    func testThemeFollowsTheShowAcrossItsEpisodesAndStopsAtRoot() {
        router.push(.item(item("s1", .series)))
        router.push(.item(item("e1", .episode, series: "s1")))
        router.push(.item(item("e2", .episode, series: "s1")))
        router.pop()
        router.pop()
        router.pop()
        XCTAssertEqual(themes, ["s1", "s1", "s1", "s1", "s1", nil])
        // What the player makes of that stream: one start, one stop.
        XCTAssertEqual(decisions(for: themes), [.start(seriesId: "s1"), .stop])
    }

    func testOpeningADifferentShowSwitchesAndBackingOutSwitchesBack() {
        router.push(.item(item("s1", .series)))
        router.push(.person(person, context))
        router.push(.item(item("s2", .series)))
        router.pop()
        XCTAssertEqual(themes, ["s1", "s1", "s2", "s1"])
        XCTAssertEqual(
            decisions(for: themes),
            [.start(seriesId: "s1"), .start(seriesId: "s2"), .start(seriesId: "s1")]
        )
    }

    func testPersonOrMoviePageKeepsTheShowBeneathIt() {
        // Under covers the series page never disappeared, so its theme played
        // on over a person or movie opened from it. Keep that.
        let path = [
            DetailRoute(.item(item("s1", .series))),
            DetailRoute(.person(person, context)),
            DetailRoute(.item(item("m1", .movie)))
        ]
        XCTAssertEqual(DetailRouter.themeSeriesID(for: path, scopeStates: [:]), "s1")
    }

    func testMovieAtRootOfPathHasNoTheme() {
        router.push(.item(item("m1", .movie)))
        XCTAssertEqual(themes, [nil])
        XCTAssertEqual(decisions(for: themes), [])
    }

    func testServerScopedShowCountsOnlyOnceItsServerIsConnected() {
        let scoped = DetailRoute(.serverMedia(source(item("s2", .series), server: "other")))
        let path = [DetailRoute(.item(item("s1", .series))), scoped]
        // Still connecting: the theme must not be looked up against the wrong
        // server, so the show beneath keeps playing.
        XCTAssertEqual(DetailRouter.themeSeriesID(for: path, scopeStates: [scoped.id: .connecting]), "s1")
        XCTAssertEqual(DetailRouter.themeSeriesID(for: path, scopeStates: [scoped.id: .failed]), "s1")
        XCTAssertEqual(DetailRouter.themeSeriesID(for: path, scopeStates: [scoped.id: .ready]), "s2")
    }

    func testPagesAboveAnUnconnectedScopeDoNotCount() {
        let scoped = DetailRoute(.serverMedia(source(item("m9", .movie), server: "other")))
        let path = [scoped, DetailRoute(.item(item("e9", .episode, series: "s9")))]
        XCTAssertNil(DetailRouter.themeSeriesID(for: path, scopeStates: [scoped.id: .connecting]))
        XCTAssertEqual(DetailRouter.themeSeriesID(for: path, scopeStates: [scoped.id: .ready]), "s9")
    }

    // MARK: - Server scopes

    func testScopeLivesWhilePagesArePushedOverItAndEndsWhenItsPageIsPopped() async {
        router.push(.serverMedia(source(item("s2", .series), server: "other")))
        let scopedRoute = router.path[0]
        XCTAssertEqual(router.scopeState(for: scopedRoute), .connecting)
        await settle()
        XCTAssertEqual(scopes.begins, ["other"])
        XCTAssertEqual(router.scopeState(for: scopedRoute), .ready)
        XCTAssertEqual(themes.last, "s2")

        // Deeper pages on that server: the scope must survive them. (A view's
        // .task would have been cancelled here.)
        router.push(.item(item("e2", .episode, series: "s2"), serverID: "other"))
        router.push(.person(person, context))
        router.pop()
        router.pop()
        await router.waitForPendingScopeEnds()
        XCTAssertTrue(scopes.ends.isEmpty)
        XCTAssertEqual(router.scopeState(for: scopedRoute), .ready)

        router.pop()
        await router.waitForPendingScopeEnds()
        XCTAssertEqual(scopes.ends.count, 1)
        XCTAssertNil(router.scopeState(for: scopedRoute))
        XCTAssertEqual(scopes.begins.count, 1, "popping must not re-begin anything")
    }

    func testPopToRootEndsNestedScopesInnermostFirst() async {
        router.push(.serverMedia(source(item("m1", .movie), server: "a")))
        await settle()
        router.push(.person(person, context))
        router.push(.serverMedia(source(item("m2", .movie), server: "b")))
        await settle()
        XCTAssertEqual(scopes.begins, ["a", "b"])

        router.popToRoot()
        await router.waitForPendingScopeEnds()
        // The same order a stack of covers unwound in: b's scope, then a's.
        XCTAssertEqual(scopes.ends, [scopes.tokens["b"], scopes.tokens["a"]].compactMap { $0 })
        XCTAssertTrue(router.scopeStates.isEmpty)
    }

    func testScopePoppedWhileConnectingIsHandedBack() async {
        scopes.holdBegins = true
        router.push(.serverMedia(source(item("m1", .movie), server: "slow")))
        await settle()
        router.pop()
        XCTAssertTrue(router.scopeStates.isEmpty)

        scopes.release()
        await settle()
        await router.waitForPendingScopeEnds()
        XCTAssertEqual(scopes.ends.count, 1, "a scope that finished connecting after its page left must be ended")
    }

    func testFailedScopeIsReported() async {
        scopes.failServers = ["gone"]
        router.push(.serverMedia(source(item("m1", .movie), server: "gone")))
        await settle()
        XCTAssertEqual(router.scopeState(for: router.path[0]), .failed)
        router.pop()
        await router.waitForPendingScopeEnds()
        XCTAssertTrue(scopes.ends.isEmpty, "nothing was begun, so nothing is ended")
    }

    func testPlainPagesNeverTouchScopes() async {
        router.push(.item(item("s1", .series)))
        router.push(.person(person, context))
        router.popToRoot()
        await settle()
        XCTAssertTrue(scopes.begins.isEmpty)
        XCTAssertTrue(scopes.ends.isEmpty)
    }

    // MARK: - Helpers

    /// Lets the router's begin tasks (main actor) run to completion.
    private func settle() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func decisions(for stream: [String?]) -> [ThemeSongVisitState.Decision] {
        var visit = ThemeSongVisitState()
        return stream.map { visit.activate(seriesId: $0) }.filter { $0 != .ignore }
    }

    private let person = PersonInfo(id: "p1", name: "Someone", role: "Lead", type: "Actor", primaryImageTag: nil)
    private let context = PersonRouteContext(excludingItemID: nil, excludingTitleKey: nil, originatingServerID: nil)

    private func source(_ item: BaseItemDto, server: String) -> ServerMediaResult {
        ServerMediaResult(
            item: item,
            serverID: server,
            serverName: server,
            serverURL: URL(string: "https://\(server).example")!
        )
    }

    private func item(_ id: String, _ type: ItemType, series: String? = nil) -> BaseItemDto {
        BaseItemDto(
            id: id, name: id, type: type,
            seriesName: nil, seriesId: series, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil, runTimeTicks: nil,
            userData: nil, imageTags: nil, backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil, taglines: nil, people: nil,
            criticRating: nil, premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }
}
