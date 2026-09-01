import XCTest
@testable import Sashimi

private struct TitleDiscoveryClientStub: SashimiTitleDiscoveryClient {
    let searchItems: [BaseItemDto]
    let latestItems: [BaseItemDto]
    let shouldFail: Bool

    func search(query: String, limit: Int) async throws -> [BaseItemDto] {
        if shouldFail { throw StubError.unavailable }
        return Array(searchItems.prefix(limit))
    }

    func getLatestMedia(
        parentId: String?,
        limit: Int,
        includeWatched: Bool,
        collectionType: String?,
        groupItems: Bool
    ) async throws -> [BaseItemDto] {
        if shouldFail { throw StubError.unavailable }
        return Array(latestItems.prefix(limit))
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
