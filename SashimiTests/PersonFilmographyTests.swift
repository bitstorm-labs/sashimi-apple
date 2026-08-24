import XCTest
@testable import Sashimi

private struct FilmographyClientStub: PeopleFilmographyClient {
    let person: PersonInfo
    let items: [BaseItemDto]
    let shouldFail: Bool

    func searchPeople(named name: String, limit: Int) async throws -> [PersonInfo] {
        if shouldFail { throw StubError.unavailable }
        return [person]
    }

    func getPersonMedia(personId: String, pageSize: Int) async throws -> [BaseItemDto] {
        if shouldFail { throw StubError.unavailable }
        return items
    }

    private enum StubError: Error {
        case unavailable
    }
}

final class PersonFilmographyTests: XCTestCase {
    func testPersonInfoDecodingAndDisplayRole() throws {
        let json = """
        {
            "Id": "person-1",
            "Name": "Taylor Example",
            "Type": "Director",
            "PrimaryImageTag": "image-tag"
        }
        """.data(using: .utf8)!

        let person = try JSONDecoder().decode(PersonInfo.self, from: json)

        XCTAssertEqual(person.id, "person-1")
        XCTAssertEqual(person.name, "Taylor Example")
        XCTAssertEqual(person.displayRole, "Director")
        XCTAssertEqual(person.primaryImageTag, "image-tag")
    }

    func testPeopleResponseDecodesJellyfinPagedResponse() throws {
        let json = """
        {
            "Items": [
                {
                    "Id": "person-1",
                    "Name": "Taylor Example",
                    "Type": "Actor"
                }
            ],
            "StartIndex": 0,
            "TotalRecordCount": 1
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(PeopleResponse.self, from: json)

        XCTAssertEqual(response.items.map(\.id), ["person-1"])
        XCTAssertEqual(response.items.first?.name, "Taylor Example")
    }

    func testPeopleResponseDecodesBareArrayForCompatibility() throws {
        let json = """
        [
            {
                "Id": "person-1",
                "Name": "Taylor Example",
                "Type": "Actor"
            }
        ]
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(PeopleResponse.self, from: json)

        XCTAssertEqual(response.items.map(\.id), ["person-1"])
    }

    func testPeopleSortActorsFirstAndPreservesCrew() {
        let people = [
            PersonInfo(id: "crew", name: "A Crew Member", role: nil, type: "Writer", primaryImageTag: nil),
            PersonInfo(id: "actor", name: "Z Actor", role: "Hero", type: "Actor", primaryImageTag: nil),
            PersonInfo(id: "actor-2", name: "A Actor", role: nil, type: "Actor", primaryImageTag: nil)
        ]

        let sorted = PersonInfo.sortedForDisplay(people)

        XCTAssertEqual(sorted.map(\.id), ["actor-2", "actor", "crew"])
        XCTAssertEqual(sorted[1].displayRole, "Hero")
    }

    func testPersonMatchingKeyIgnoresPunctuationCaseAndDiacritics() {
        XCTAssertEqual(
            PersonInfo.matchingNameKey(for: "Robert Downey Jr."),
            PersonInfo.matchingNameKey(for: "robert downey jr")
        )
        XCTAssertEqual(
            PersonInfo.matchingNameKey(for: "Zoë Kravitz"),
            PersonInfo.matchingNameKey(for: "Zoe Kravitz")
        )
    }

    func testDisplayYearUsesProductionYearThenPremiereDate() {
        let productionYearItem = makeItem(
            id: "production-year",
            type: .movie,
            productionYear: 2024,
            premiereDate: "2024-03-01T00:00:00Z"
        )
        let premiereDateItem = makeItem(
            id: "premiere-date",
            type: .movie,
            productionYear: nil,
            premiereDate: "2023-11-17T00:00:00Z"
        )

        XCTAssertEqual(productionYearItem.displayYear, 2024)
        XCTAssertEqual(premiereDateItem.displayYear, 2023)
    }

    @MainActor
    func testOfflineFilmographyDoesNotShowStaleItems() async {
        let viewModel = PersonFilmographyViewModel()

        let person = PersonInfo(
            id: "person-1",
            name: "Taylor Example",
            role: nil,
            type: "Actor",
            primaryImageTag: nil
        )
        await viewModel.load(person: person, originatingServerID: nil, isOffline: true)

        let state = viewModel.state
        let items = viewModel.items
        XCTAssertEqual(state, .unavailable)
        XCTAssertTrue(items.isEmpty)
    }

    @MainActor
    func testVisibleServerMediaExcludesCurrentTitleAcrossServerCopies() {
        let currentItem = makeItem(id: "origin-title", name: "Shared Title", type: .movie)
        let copyOnAnotherServer = makeItem(id: "copy-title", name: "Shared Title", type: .movie)
        let otherItem = makeItem(id: "other-title", name: "Other Title", type: .series)
        let results = [
            ServerMediaResult(
                item: currentItem,
                serverID: "origin",
                serverName: "Origin",
                serverURL: URL(string: "https://origin.example")!
            ),
            ServerMediaResult(
                item: copyOnAnotherServer,
                serverID: "other-server",
                serverName: "Other Server",
                serverURL: URL(string: "https://other.example")!
            ),
            ServerMediaResult(
                item: otherItem,
                serverID: "other-server",
                serverName: "Other Server",
                serverURL: URL(string: "https://other.example")!
            )
        ]

        let visible = PersonFilmographyViewModel.visibleMedia(
            from: results,
            excludingItemID: currentItem.id,
            excludingServerID: "origin",
            excludingTitleKey: ServerMediaResultGrouping.titleKey(for: currentItem)
        )

        XCTAssertEqual(visible.map { $0.item.id }, ["other-title"])
    }

    func testFilmographyAggregationKeepsPartialSuccess() throws {
        let item = makeItem(id: "server-a-title", type: .movie)
        let response = MultiServerPeopleServerResult(
            items: [
                ServerMediaResult(
                    item: item,
                    serverID: "server-a",
                    serverName: "Server A",
                    serverURL: URL(string: "https://server-a.example")!
                )
            ],
            succeeded: true
        )

        let results = try MultiServerPeopleService.aggregateFilmographyResults(
            [response, MultiServerPeopleServerResult(items: [], succeeded: false)],
            attemptedServerCount: 2
        )

        XCTAssertEqual(results.map(\.serverID), ["server-a"])
    }

    func testFilmographyAggregationFailsWhenEveryServerFails() {
        XCTAssertThrowsError(
            try MultiServerPeopleService.aggregateFilmographyResults(
                [MultiServerPeopleServerResult(items: [], succeeded: false)],
                attemptedServerCount: 1
            )
        ) { error in
            XCTAssertEqual(error as? MultiServerPeopleError, .allServersFailed)
        }
    }

    func testFilmographyAggregationFailsWhenNoServerSessionIsAvailable() {
        XCTAssertThrowsError(
            try MultiServerPeopleService.aggregateFilmographyResults([], attemptedServerCount: 0)
        ) { error in
            XCTAssertEqual(error as? MultiServerPeopleError, .noAvailableServerSessions)
        }
    }

    func testFilmographySearchKeepsAProductionPathPartialSuccess() async throws {
        let person = PersonInfo(
            id: "person-a",
            name: "Taylor Example",
            role: nil,
            type: "Actor",
            primaryImageTag: nil
        )
        let servers = [
            ServerConfig(
                id: "server-a",
                name: "Server A",
                url: URL(string: "https://server-a.example")!,
                username: "user",
                userId: "user-a"
            ),
            ServerConfig(
                id: "server-b",
                name: "Server B",
                url: URL(string: "https://server-b.example")!,
                username: "user",
                userId: "user-b"
            )
        ]
        let media = makeItem(id: "movie-a", type: .movie)

        let results = try await MultiServerPeopleService.search(
            person: person,
            originatingServerID: "server-a",
            servers: servers,
            tokenProvider: { _ in "test-token" },
            clientFactory: { server, _ in
                FilmographyClientStub(
                    person: person,
                    items: media.id == "movie-a" && server.id == "server-a" ? [media] : [],
                    shouldFail: server.id == "server-b"
                )
            }
        )

        XCTAssertEqual(results.map(\.item.id), ["movie-a"])
        XCTAssertEqual(results.first?.serverID, "server-a")
    }

    func testFilmographySearchReportsProductionPathOutage() async {
        let person = PersonInfo(
            id: "person-a",
            name: "Taylor Example",
            role: nil,
            type: "Actor",
            primaryImageTag: nil
        )
        let server = ServerConfig(
            id: "server-a",
            name: "Server A",
            url: URL(string: "https://server-a.example")!,
            username: "user",
            userId: "user-a"
        )

        do {
            _ = try await MultiServerPeopleService.search(
                person: person,
                originatingServerID: server.id,
                servers: [server],
                tokenProvider: { _ in "test-token" },
                clientFactory: { _, _ in
                    FilmographyClientStub(person: person, items: [], shouldFail: true)
                }
            )
            XCTFail("An all-server filmography outage should throw")
        } catch {
            XCTAssertEqual(error as? MultiServerPeopleError, .allServersFailed)
        }
    }

    private func makeItem(
        id: String,
        name: String? = nil,
        type: ItemType,
        productionYear: Int? = nil,
        premiereDate: String? = nil
    ) -> BaseItemDto {
        BaseItemDto(
            id: id,
            name: name ?? id,
            type: type,
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
            productionYear: productionYear,
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
