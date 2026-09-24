import XCTest
@testable import Sashimi

@MainActor
final class GuideViewModelTests: XCTestCase {
    /// Answers a scripted sequence of guide responses, one per load.
    private final class ScriptedClient: GuideClient, @unchecked Sendable {
        var responses: [Result<[ChannelGuide], Error>]
        init(_ responses: [Result<[ChannelGuide], Error>]) { self.responses = responses }

        func getChannelGuide(hours: Double) async throws -> [ChannelGuide] {
            try responses.removeFirst().get()
        }

        func getChannelNowPlaying(channelId: String) async throws -> ChannelNowPlaying? { nil }

        func getItem(itemId: String) async throws -> BaseItemDto {
            BaseItemDto(
                id: itemId, name: "Item \(itemId)", type: .movie,
                seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
                indexNumber: nil, parentIndexNumber: nil, overview: nil,
                runTimeTicks: nil, userData: nil, imageTags: nil,
                backdropImageTags: nil, parentBackdropImageTags: nil,
                primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
                communityRating: nil, officialRating: nil, genres: nil,
                taglines: nil, people: nil, criticRating: nil,
                premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil, localTrailerCount: nil, mediaStreams: nil
            )
        }
    }

    private struct Unreachable: Error {}

    /// Built from JSON because GuideEntry only has a decoding initialiser —
    /// the server's seven-digit fractional seconds are exactly what its
    /// date parsing exists for, so this is also the honest way to make one.
    private func guide(_ id: String) -> ChannelGuide {
        let json = """
        {"Id":"\(id)","Name":"Channel \(id)","Description":null,
         "Programs":[{"ItemId":"item-\(id)","StartUtc":"2026-09-23T20:00:00.0000000Z",
                      "EndUtc":"2026-09-23T20:30:00.0000000Z","StartPositionSeconds":0}]}
        """
        return try! JSONDecoder().decode(ChannelGuide.self, from: Data(json.utf8))
    }

    func testFailedRefreshKeepsTheRowsAlreadyShown() async {
        // The guide reloads itself every minute. One dropped request must not
        // wipe a grid the viewer is looking at.
        let client = ScriptedClient([.success([guide("a"), guide("b")]), .failure(Unreachable())])
        let model = GuideViewModel(client: client)

        await model.load()
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"])

        await model.load()
        XCTAssertEqual(model.rows.map(\.id), ["a", "b"], "a failed refresh cleared rows the viewer was looking at")
        XCTAssertTrue(model.loadFailed)
    }

    func testFailedFirstLoadReportsFailureWithNoRows() async {
        let model = GuideViewModel(client: ScriptedClient([.failure(Unreachable())]))

        await model.load()
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertTrue(model.loadFailed)
        XCTAssertFalse(model.isLoading)
    }

    func testSuccessfulLoadClearsAnEarlierFailure() async {
        let client = ScriptedClient([.failure(Unreachable()), .success([guide("a")])])
        let model = GuideViewModel(client: client)

        await model.load()
        await model.load()
        XCTAssertEqual(model.rows.map(\.id), ["a"])
        XCTAssertFalse(model.loadFailed)
    }
}
