import XCTest
@testable import Sashimi

final class SearchResultGroupingTests: XCTestCase {
    private func makeItem(id: String, name: String? = nil, type: ItemType, productionYear: Int? = nil) -> BaseItemDto {
        BaseItemDto(
            id: id, name: name ?? id, type: type,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: productionYear,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }

    private func makeResult(
        id: String,
        name: String? = nil,
        type: ItemType,
        serverID: String = "server-1",
        serverName: String = "Server",
        serverURL: URL = URL(string: "https://server.example")!
    ) -> ServerMediaResult {
        ServerMediaResult(
            item: makeItem(id: id, name: name, type: type),
            serverID: serverID,
            serverName: serverName,
            serverURL: serverURL
        )
    }

    func testMoviesComeBeforeShows() {
        let items = [
            makeResult(id: "s1", type: .series),
            makeResult(id: "m1", type: .movie),
            makeResult(id: "s2", type: .series),
            makeResult(id: "m2", type: .movie)
        ]
        let groups = SearchResultGrouping.groups(from: ServerMediaResultGrouping.groups(from: items))
        XCTAssertEqual(groups.map(\.title), ["Movies", "TV Shows"])
        XCTAssertEqual(groups[0].items.map { $0.primary.item.id }, ["m1", "m2"])
        XCTAssertEqual(groups[1].items.map { $0.primary.item.id }, ["s1", "s2"])
    }

    func testEmptySectionsAreDropped() {
        let groups = SearchResultGrouping.groups(from: ServerMediaResultGrouping.groups(from: [
            makeResult(id: "m1", type: .movie),
            makeResult(id: "m2", type: .movie)
        ]))
        XCTAssertEqual(groups.map(\.title), ["Movies"])
    }

    func testServerOrderIsPreservedWithinASection() {
        let items = [
            makeResult(id: "m3", type: .movie),
            makeResult(id: "m1", type: .movie),
            makeResult(id: "m2", type: .movie)
        ]
        let groups = SearchResultGrouping.groups(from: ServerMediaResultGrouping.groups(from: items))
        XCTAssertEqual(groups.first?.items.map { $0.primary.item.id }, ["m3", "m1", "m2"])
    }

    func testUnexpectedTypesCollectIntoOther() {
        // Nothing the server returns should be silently dropped.
        let groups = SearchResultGrouping.groups(from: ServerMediaResultGrouping.groups(from: [
            makeResult(id: "m1", type: .movie),
            makeResult(id: "e1", type: .episode),
            makeResult(id: "v1", type: .video)
        ]))
        XCTAssertEqual(groups.map(\.title), ["Movies", "Other"])
        XCTAssertEqual(groups.last?.items.map { $0.primary.item.id }, ["e1", "v1"])
    }

    func testEmptyInputYieldsNoGroups() {
        XCTAssertTrue(SearchResultGrouping.groups(from: ServerMediaResultGrouping.groups(from: [])).isEmpty)
    }

    func testSameTitleAcrossServersBecomesOneGroupWithServerSources() {
        let results = [
            makeResult(id: "finny-title", name: "Harry Potter", type: .movie, serverID: "finny", serverName: "finny"),
            makeResult(id: "jelly-title", name: "Harry Potter", type: .movie, serverID: "jelly", serverName: "JellyPal")
        ]

        let groups = ServerMediaResultGrouping.groups(from: results)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sources.map(\.serverName), ["finny", "JellyPal"])
    }

    func testPreferredServerIsPrimarySource() {
        let results = [
            makeResult(id: "finny-title", name: "Harry Potter", type: .movie, serverID: "finny", serverName: "finny"),
            makeResult(id: "jelly-title", name: "Harry Potter", type: .movie, serverID: "jelly", serverName: "JellyPal")
        ]

        let groups = ServerMediaResultGrouping.groups(from: results, preferredServerID: "jelly")

        XCTAssertEqual(groups.first?.primary.serverID, "jelly")
    }

    func testSameTitleAcrossMoreThanFiveServersRetainsEverySource() {
        let results = (1...7).map { index in
            makeResult(
                id: "title-\(index)",
                name: "Mission Impossible",
                type: .movie,
                serverID: "server-\(index)",
                serverName: "Server \(index)"
            )
        }

        let groups = ServerMediaResultGrouping.groups(from: results)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].sources.count, 7)
        XCTAssertEqual(Set(groups[0].sources.map(\.serverID)), Set((1...7).map { "server-\($0)" }))
    }

    func testServerAvailabilityBadgeOnlyAppearsForMultipleSources() {
        XCTAssertNil(ServerAvailabilityBadge.title(for: 0))
        XCTAssertNil(ServerAvailabilityBadge.title(for: 1))
        XCTAssertEqual(ServerAvailabilityBadge.title(for: 2), "2 servers")
        XCTAssertEqual(ServerAvailabilityBadge.title(for: 7), "7 servers")
    }
}
