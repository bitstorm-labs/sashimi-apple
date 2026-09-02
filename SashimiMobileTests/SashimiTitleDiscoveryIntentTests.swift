import XCTest
@testable import SashimiMobile

final class SashimiTitleDiscoveryIntentTests: XCTestCase {
    func testFindIntentRejectsBlankQueryBeforeNetworkWork() async {
        let intent = FindSashimiTitlesIntent()
        intent.query = " \n  "

        do {
            _ = try await intent.perform()
            XCTFail("Expected a blank query to be rejected")
        } catch let error as SashimiTitleDiscoveryIntentError {
            XCTAssertEqual(error, .emptySearchQuery)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFindIntentForwardsNormalizedArgumentsAndReturnsServerScopedEntity() async throws {
        let server = Self.makeServer(id: "server-one")
        let source = ServerMediaResult(
            item: Self.makeItem(id: "item-one", name: "The Title"),
            serverID: server.id,
            serverName: server.displayName,
            serverURL: server.url
        )
        let recorder = IntentSearchRecorder()

        let result = try await SashimiTitleDiscoveryIntentDependencies.$searchProvider.withValue(
            { query, limit, serverID in
                await recorder.record(query: query, limit: limit, serverID: serverID)
                return [source]
            },
            operation: {
                let intent = FindSashimiTitlesIntent()
                intent.query = "  The Title  "
                intent.limit = 7
                intent.server = SashimiServerEntity(server: server)
                return try await intent.perform()
            }
        )

        let request = await recorder.request
        XCTAssertEqual(request?.query, "The Title")
        XCTAssertEqual(request?.limit, 7)
        XCTAssertEqual(request?.serverID, server.id)
        XCTAssertEqual(result.value?.map { $0.id }, ["10:server-oneitem-one"])
    }

    private static func makeServer(id: String) -> ServerConfig {
        ServerConfig(
            id: id,
            name: "Test Server",
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

private actor IntentSearchRecorder {
    struct Request: Sendable {
        let query: String
        let limit: Int
        let serverID: String?
    }

    private(set) var request: Request?

    func record(query: String, limit: Int, serverID: String?) {
        request = Request(query: query, limit: limit, serverID: serverID)
    }
}
