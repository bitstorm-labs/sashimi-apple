import XCTest
@testable import Sashimi

private struct TitleDiscoverySearchRequest: Equatable, Sendable {
    let query: String
    let limit: Int
}

private struct TitleDiscoveryLatestRequest: Equatable, Sendable {
    let parentId: String?
    let limit: Int
    let includeWatched: Bool
    let collectionType: String?
    let groupItems: Bool
}

private struct TitleDiscoveryRequestSnapshot: Equatable, Sendable {
    let searchRequests: [TitleDiscoverySearchRequest]
    let latestRequests: [TitleDiscoveryLatestRequest]
}

private actor TitleDiscoveryRequestRecorder {
    private var searchRequests: [TitleDiscoverySearchRequest] = []
    private var latestRequests: [TitleDiscoveryLatestRequest] = []

    func recordSearch(query: String, limit: Int) {
        searchRequests.append(TitleDiscoverySearchRequest(query: query, limit: limit))
    }

    func recordLatest(
        parentId: String?,
        limit: Int,
        includeWatched: Bool,
        collectionType: String?,
        groupItems: Bool
    ) {
        latestRequests.append(
            TitleDiscoveryLatestRequest(
                parentId: parentId,
                limit: limit,
                includeWatched: includeWatched,
                collectionType: collectionType,
                groupItems: groupItems
            )
        )
    }

    func snapshot() -> TitleDiscoveryRequestSnapshot {
        TitleDiscoveryRequestSnapshot(
            searchRequests: searchRequests,
            latestRequests: latestRequests
        )
    }
}

private struct TitleDiscoveryClientStub: SashimiTitleDiscoveryClient {
    let searchItems: [BaseItemDto]
    let latestItems: [BaseItemDto]
    let failure: StubFailure?
    let recorder: TitleDiscoveryRequestRecorder?

    init(
        searchItems: [BaseItemDto],
        latestItems: [BaseItemDto],
        shouldFail: Bool,
        failure: StubFailure? = nil,
        recorder: TitleDiscoveryRequestRecorder? = nil
    ) {
        self.searchItems = searchItems
        self.latestItems = latestItems
        self.failure = failure ?? (shouldFail ? .unavailable : nil)
        self.recorder = recorder
    }

    func search(query: String, limit: Int) async throws -> [BaseItemDto] {
        await recorder?.recordSearch(query: query, limit: limit)
        try throwIfNeeded()
        return Array(searchItems.prefix(limit))
    }

    func getLatestMedia(
        parentId: String?,
        limit: Int,
        includeWatched: Bool,
        collectionType: String?,
        groupItems: Bool
    ) async throws -> [BaseItemDto] {
        await recorder?.recordLatest(
            parentId: parentId,
            limit: limit,
            includeWatched: includeWatched,
            collectionType: collectionType,
            groupItems: groupItems
        )
        try throwIfNeeded()
        return Array(latestItems.prefix(limit))
    }

    private func throwIfNeeded() throws {
        guard let failure else { return }
        switch failure {
        case .unavailable:
            throw StubError.unavailable
        case .sessionExpired:
            throw JellyfinError.sessionExpired
        }
    }

    enum StubFailure: Error, Sendable {
        case unavailable
        case sessionExpired
    }

    private enum StubError: Error {
        case unavailable
    }
}

final class MultiServerTitleDiscoveryServiceTests: XCTestCase {
    func testSearchInterleavesServersBeforeApplyingLimit() async throws {
        let servers = [Self.makeServer(id: "server-1"), Self.makeServer(id: "server-2")]
        let clientFactory: MultiServerTitleDiscoveryService.ClientFactory = { server, _ in
            TitleDiscoveryClientStub(
                searchItems: [
                    Self.makeItem(id: "\(server.id)-1", name: "First \(server.id)"),
                    Self.makeItem(id: "\(server.id)-2", name: "Second \(server.id)")
                ],
                latestItems: [],
                shouldFail: false
            )
        }

        let results = try await MultiServerTitleDiscoveryService.search(
            query: "title",
            limit: 3,
            servers: servers,
            tokenProvider: { _ in "token" },
            clientFactory: clientFactory
        )

        XCTAssertEqual(
            results.map(\.id),
            ["server-1:server-1-1", "server-2:server-2-1", "server-1:server-1-2"]
        )
    }

    func testSearchReturnsPartialSuccessWhenOneServerFails() async throws {
        let servers = [Self.makeServer(id: "offline"), Self.makeServer(id: "online")]
        let clientFactory: MultiServerTitleDiscoveryService.ClientFactory = { server, _ in
            TitleDiscoveryClientStub(
                searchItems: server.id == "online"
                    ? [Self.makeItem(id: "online-title", name: "Available title")]
                    : [],
                latestItems: [],
                shouldFail: server.id == "offline"
            )
        }

        let results = try await MultiServerTitleDiscoveryService.search(
            query: "title",
            limit: 10,
            servers: servers,
            tokenProvider: { _ in "token" },
            clientFactory: clientFactory
        )

        XCTAssertEqual(results.map(\.item.id), ["online-title"])
    }

    func testSearchReturnsPartialSuccessWhenOneServerSessionExpires() async throws {
        let servers = [Self.makeServer(id: "expired"), Self.makeServer(id: "online")]
        let clientFactory: MultiServerTitleDiscoveryService.ClientFactory = { server, _ in
            TitleDiscoveryClientStub(
                searchItems: server.id == "online"
                    ? [Self.makeItem(id: "online-title", name: "Available title")]
                    : [],
                latestItems: [],
                shouldFail: false,
                failure: server.id == "expired" ? .sessionExpired : nil
            )
        }

        let results = try await MultiServerTitleDiscoveryService.search(
            query: "title",
            limit: 10,
            servers: servers,
            tokenProvider: { _ in "token" },
            clientFactory: clientFactory
        )

        XCTAssertEqual(results.map(\.item.id), ["online-title"])
    }

    func testSearchTreatsExpiredExplicitServerAsAuthenticationFailure() async {
        let server = Self.makeServer(id: "expired")
        let clientFactory: MultiServerTitleDiscoveryService.ClientFactory = { _, _ in
            TitleDiscoveryClientStub(
                searchItems: [],
                latestItems: [],
                shouldFail: false,
                failure: .sessionExpired
            )
        }

        do {
            _ = try await MultiServerTitleDiscoveryService.search(
                query: "title",
                limit: 10,
                serverID: server.id,
                servers: [server],
                tokenProvider: { _ in "expired-token" },
                clientFactory: clientFactory
            )
            XCTFail("Expected the expired session to require authentication")
        } catch let error as MultiServerTitleDiscoveryError {
            XCTAssertEqual(error, .serverAuthenticationRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSearchTreatsAllExpiredServerSessionsAsAuthenticationFailure() async {
        let servers = [Self.makeServer(id: "expired-1"), Self.makeServer(id: "expired-2")]
        let clientFactory: MultiServerTitleDiscoveryService.ClientFactory = { _, _ in
            TitleDiscoveryClientStub(
                searchItems: [],
                latestItems: [],
                shouldFail: false,
                failure: .sessionExpired
            )
        }

        do {
            _ = try await MultiServerTitleDiscoveryService.search(
                query: "title",
                limit: 10,
                servers: servers,
                tokenProvider: { _ in "expired-token" },
                clientFactory: clientFactory
            )
            XCTFail("Expected expired sessions to require authentication")
        } catch let error as MultiServerTitleDiscoveryError {
            XCTAssertEqual(error, .serverAuthenticationRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSearchForwardsQueryAndLimitToJellyfinAndKeepsServerIdentity() async throws {
        let server = Self.makeServer(id: "server-1")
        let recorder = TitleDiscoveryRequestRecorder()
        let clientFactory: MultiServerTitleDiscoveryService.ClientFactory = { _, _ in
            TitleDiscoveryClientStub(
                searchItems: [Self.makeItem(id: "title-1", name: "Title")],
                latestItems: [],
                shouldFail: false,
                recorder: recorder
            )
        }

        let results = try await MultiServerTitleDiscoveryService.search(
            query: "The Title",
            limit: 4,
            servers: [server],
            tokenProvider: { _ in "token" },
            clientFactory: clientFactory
        )

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(
            snapshot.searchRequests,
            [TitleDiscoverySearchRequest(query: "The Title", limit: 4)]
        )
        XCTAssertEqual(results.map(\.id), ["server-1:title-1"])
    }

    func testSearchWithoutAuthenticatedSessionsThrows() async {
        do {
            _ = try await MultiServerTitleDiscoveryService.search(
                query: "title",
                limit: 10,
                servers: [Self.makeServer(id: "signed-out")],
                tokenProvider: { _ in nil },
                clientFactory: { _, _ in
                    TitleDiscoveryClientStub(searchItems: [], latestItems: [], shouldFail: false)
                }
            )
            XCTFail("Expected the search to require an authenticated server")
        } catch let error as MultiServerTitleDiscoveryError {
            XCTAssertEqual(error, .noAvailableServerSessions)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testExplicitServerWithoutAuthenticationThrowsAuthenticationError() async {
        do {
            _ = try await MultiServerTitleDiscoveryService.search(
                query: "title",
                limit: 10,
                serverID: "signed-out",
                servers: [Self.makeServer(id: "signed-out")],
                tokenProvider: { _ in nil },
                clientFactory: { _, _ in
                    TitleDiscoveryClientStub(searchItems: [], latestItems: [], shouldFail: false)
                }
            )
            XCTFail("Expected the explicit server to require authentication")
        } catch let error as MultiServerTitleDiscoveryError {
            XCTAssertEqual(error, .serverAuthenticationRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRecentlyAddedUsesDefaultServerAndPreservesServerOrder() async throws {
        let servers = [Self.makeServer(id: "other"), Self.makeServer(id: "default")]
        let clientFactory: MultiServerTitleDiscoveryService.ClientFactory = { server, _ in
            TitleDiscoveryClientStub(
                searchItems: [],
                latestItems: [
                    Self.makeItem(id: "\(server.id)-newest", name: "Newest"),
                    Self.makeItem(id: "\(server.id)-next", name: "Next")
                ],
                shouldFail: false
            )
        }

        let results = try await MultiServerTitleDiscoveryService.recentlyAdded(
            limit: 1,
            servers: servers,
            defaultServerID: "default",
            tokenProvider: { _ in "token" },
            clientFactory: clientFactory
        )

        XCTAssertEqual(results.map(\.item.id), ["default-newest"])
        XCTAssertEqual(results.map(\.serverID), ["default"])
    }

    func testRecentlyAddedExplicitServerOverridesDefault() async throws {
        let servers = [Self.makeServer(id: "other"), Self.makeServer(id: "default")]
        let clientFactory: MultiServerTitleDiscoveryService.ClientFactory = { server, _ in
            TitleDiscoveryClientStub(
                searchItems: [],
                latestItems: [Self.makeItem(id: server.id, name: server.id)],
                shouldFail: false
            )
        }

        let results = try await MultiServerTitleDiscoveryService.recentlyAdded(
            limit: 10,
            serverID: "other",
            servers: servers,
            defaultServerID: "default",
            tokenProvider: { _ in "token" },
            clientFactory: clientFactory
        )

        XCTAssertEqual(results.map(\.serverID), ["other"])
    }

    func testRecentlyAddedForwardsExpectedJellyfinRequestParameters() async throws {
        let server = Self.makeServer(id: "default")
        let recorder = TitleDiscoveryRequestRecorder()
        let clientFactory: MultiServerTitleDiscoveryService.ClientFactory = { _, _ in
            TitleDiscoveryClientStub(
                searchItems: [],
                latestItems: [Self.makeItem(id: "new-title", name: "New title")],
                shouldFail: false,
                recorder: recorder
            )
        }

        _ = try await MultiServerTitleDiscoveryService.recentlyAdded(
            limit: 3,
            servers: [server],
            defaultServerID: server.id,
            tokenProvider: { _ in "token" },
            clientFactory: clientFactory
        )

        let snapshot = await recorder.snapshot()
        XCTAssertEqual(
            snapshot.latestRequests,
            [
                TitleDiscoveryLatestRequest(
                    parentId: nil,
                    limit: 3,
                    includeWatched: true,
                    collectionType: nil,
                    groupItems: true
                )
            ]
        )
    }

    func testRecentlyAddedWithoutDefaultServerThrows() async {
        do {
            _ = try await MultiServerTitleDiscoveryService.recentlyAdded(
                limit: 10,
                servers: [Self.makeServer(id: "server")],
                defaultServerID: nil,
                tokenProvider: { _ in "token" },
                clientFactory: { _, _ in
                    TitleDiscoveryClientStub(searchItems: [], latestItems: [], shouldFail: false)
                }
            )
            XCTFail("Expected the default server to be required")
        } catch let error as MultiServerTitleDiscoveryError {
            XCTAssertEqual(error, .defaultServerUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBoundedLimitClampsInvalidValues() {
        XCTAssertEqual(MultiServerTitleDiscoveryService.boundedLimit(0), 1)
        XCTAssertEqual(MultiServerTitleDiscoveryService.boundedLimit(10), 10)
        XCTAssertEqual(MultiServerTitleDiscoveryService.boundedLimit(100), 50)
    }

    private static func makeServer(id: String) -> ServerConfig {
        ServerConfig(
            id: id,
            name: id,
            url: URL(string: "https://\(id).example.com") ?? URL(fileURLWithPath: "/"),
            username: "user",
            userId: "user-id"
        )
    }

    private static func makeItem(id: String, name: String) -> BaseItemDto {
        BaseItemDto(
            id: id,
            name: name,
            type: .movie,
            seriesName: nil,
            seriesId: nil,
            seasonId: nil,
            parentId: nil,
            indexNumber: nil,
            parentIndexNumber: nil,
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
            premiereDate: nil,
            chapters: nil,
            path: nil,
            remoteTrailers: nil,
            localTrailerCount: nil,
            mediaStreams: nil
        )
    }
}
