import XCTest
@testable import Sashimi

/// Library Shuffle for TV (roku#141 parity): Random Episode (the original
/// behaviour, and the default) or Random Show, Next Episode.
final class TVShuffleTests: XCTestCase {
    /// A fake server: one random answer per item type, and per-series Next Up
    /// and first-regular answers. Records every random request.
    private final class FakeSource: TVShuffleSource, @unchecked Sendable {
        var random: [ItemType: BaseItemDto] = [:]
        var nextUp: [String: BaseItemDto] = [:]
        var firstUnwatchedRegular: [String: BaseItemDto] = [:]
        var firstRegular: [String: BaseItemDto] = [:]
        private(set) var randomRequests: [(parentId: String, types: [ItemType])] = []

        func randomItem(parentId: String, itemTypes: [ItemType]) async throws -> BaseItemDto? {
            randomRequests.append((parentId, itemTypes))
            return itemTypes.lazy.compactMap { self.random[$0] }.first
        }

        func nextUpEpisode(seriesId: String) async throws -> BaseItemDto? { nextUp[seriesId] }

        func firstRegularEpisode(seriesId: String, unplayedOnly: Bool) async throws -> BaseItemDto? {
            unplayedOnly ? firstUnwatchedRegular[seriesId] : firstRegular[seriesId]
        }
    }

    private func item(_ id: String, type: ItemType, season: Int? = nil, seriesId: String? = nil) -> BaseItemDto {
        BaseItemDto(
            id: id, name: id, type: type,
            seriesName: nil, seriesId: seriesId, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: season, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }

    private func pick(_ mode: TVShuffleMode, _ source: FakeSource, types: [ItemType] = [.episode]) async throws -> BaseItemDto? {
        try await TVShuffle.pick(libraryId: "lib", itemTypes: types, mode: mode, source: source)
    }

    func testDefaultModeIsRandomEpisode() {
        XCTAssertEqual(PlaybackSettings.defaultTVShuffleMode, .randomEpisode)
    }

    func testRandomEpisodePicksAnyEpisodeInTheLibrary() async throws {
        let source = FakeSource()
        source.random[.episode] = item("ep", type: .episode, season: 3)
        source.random[.series] = item("show", type: .series)
        let picked = try await pick(.randomEpisode, source)
        XCTAssertEqual(picked?.id, "ep")
        XCTAssertEqual(source.randomRequests.map(\.types), [[.episode]])
    }

    func testRandomShowPlaysThatShowsNextUpEpisode() async throws {
        let source = FakeSource()
        source.random[.series] = item("show", type: .series)
        source.random[.episode] = item("random-ep", type: .episode, season: 2)
        source.nextUp["show"] = item("s2e4", type: .episode, season: 2, seriesId: "show")
        source.firstUnwatchedRegular["show"] = item("s1e1", type: .episode, season: 1)
        let picked = try await pick(.randomShowNextEpisode, source)
        XCTAssertEqual(picked?.id, "s2e4")
        XCTAssertEqual(source.randomRequests.first?.parentId, "lib")
        XCTAssertEqual(source.randomRequests.first?.types, [.series])
    }

    func testRandomShowWithoutNextUpPlaysFirstUnwatchedRegularEpisode() async throws {
        let source = FakeSource()
        source.random[.series] = item("show", type: .series)
        source.firstUnwatchedRegular["show"] = item("s1e3", type: .episode, season: 1)
        source.firstRegular["show"] = item("s1e1", type: .episode, season: 1)
        let picked = try await pick(.randomShowNextEpisode, source)
        XCTAssertEqual(picked?.id, "s1e3")
    }

    func testRandomShowSkipsASpecialWhileRegularEpisodesAreUnwatched() async throws {
        let source = FakeSource()
        source.random[.series] = item("show", type: .series)
        source.nextUp["show"] = item("s0e9", type: .episode, season: 0)
        source.firstUnwatchedRegular["show"] = item("s1e1", type: .episode, season: 1)
        let picked = try await pick(.randomShowNextEpisode, source)
        XCTAssertEqual(picked?.id, "s1e1")
    }

    func testFullyWatchedShowRestartsAtItsFirstRegularEpisode() async throws {
        let source = FakeSource()
        source.random[.series] = item("show", type: .series)
        source.firstRegular["show"] = item("s1e1", type: .episode, season: 1)
        let picked = try await pick(.randomShowNextEpisode, source)
        XCTAssertEqual(picked?.id, "s1e1")
    }

    func testRandomShowIsNilForAnEmptyLibrary() async throws {
        let picked = try await pick(.randomShowNextEpisode, FakeSource())
        XCTAssertNil(picked)
    }

    func testMovieLibraryIgnoresTheTVMode() async throws {
        let source = FakeSource()
        source.random[.movie] = item("movie", type: .movie)
        source.random[.series] = item("show", type: .series)
        let picked = try await pick(.randomShowNextEpisode, source, types: [.movie])
        XCTAssertEqual(picked?.id, "movie")
        XCTAssertEqual(source.randomRequests.map(\.types), [[.movie]])
    }
}

/// The stored setting: absent means the default, a stored raw value wins.
@MainActor
final class TVShuffleSettingTests: XCTestCase {
    private let key = "tvShuffleMode"
    private var previous: Any?

    override func setUp() {
        super.setUp()
        previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testNothingStoredReadsAsRandomEpisode() {
        XCTAssertEqual(PlaybackSettings().tvShuffleMode, .randomEpisode)
    }

    func testStoredModeIsRead() {
        UserDefaults.standard.set(TVShuffleMode.randomShowNextEpisode.rawValue, forKey: key)
        XCTAssertEqual(PlaybackSettings().tvShuffleMode, .randomShowNextEpisode)
    }
}
