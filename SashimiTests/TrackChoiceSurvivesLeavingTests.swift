import XCTest
import AVFoundation
@testable import Sashimi

/// #774: leaving the app stops the player (iPhone, iPad; the Mac did too), and
/// the audio and subtitle picks went with it. Reopening the item fell back to
/// the Settings language, which never burns in an image subtitle and cannot
/// tell SDH from the plain track, so subtitles came back off or wrong.
///
/// Driven through API that existed before the fix (`sessionSubtitlePreference`,
/// `beginStop`, `setCurrentItem`, `trackRequest`), so the file compiles against
/// the old code and each test fails there on its assertion.
@MainActor
final class TrackChoiceSurvivesLeavingTests: XCTestCase {
    private var itemID = ""

    override func setUp() {
        super.setUp()
        // A fresh id per test: the memory is the app's real store.
        itemID = "track-memory-\(UUID().uuidString)"
    }

    func testAnImageSubtitlePickIsBurnedInAgainAfterLeavingAndReopening() async {
        let leaving = makeViewModel()
        leaving.sessionSubtitlePreference = .init(language: "eng", displayTitle: "English PGS", isExternal: false)
        await leaving.beginStop(reason: .sceneBackground).value

        let reopened = makeViewModel()
        reopened.setCurrentItem(makeItem())
        let request = reopened.trackRequest(mediaSourceId: "source", streams: streams)

        XCTAssertEqual(request.subtitleStreamIndex, 4, "the PGS track must be asked for again, not dropped to off")
    }

    func testTheExactTextTrackAndAudioPickComeBack() async {
        let leaving = makeViewModel()
        leaving.sessionSubtitlePreference = .init(language: "eng", displayTitle: "English SDH", isExternal: false)
        leaving.sessionAudioPreference = .init(language: "jpn", displayName: "Japanese")
        await leaving.beginStop(reason: .sceneBackground).value

        let reopened = makeViewModel()
        reopened.setCurrentItem(makeItem())

        XCTAssertEqual(reopened.sessionSubtitlePreference?.displayTitle, "English SDH")
        XCTAssertEqual(reopened.sessionAudioPreference?.displayName, "Japanese")
        XCTAssertEqual(reopened.trackRequest(mediaSourceId: "source", streams: streams).audioStreamIndex, 2)
    }

    func testTurningSubtitlesOffBeforeLeavingIsNotUndone() async {
        let first = makeViewModel()
        first.sessionSubtitlePreference = .init(language: "eng", displayTitle: "English SDH", isExternal: false)
        await first.beginStop(reason: .sceneBackground).value

        // Reopened, then subtitles turned off before leaving again.
        let second = makeViewModel()
        second.setCurrentItem(makeItem())
        second.sessionSubtitlePreference = nil
        await second.beginStop(reason: .sceneBackground).value

        let third = makeViewModel()
        third.setCurrentItem(makeItem())
        XCTAssertNil(third.sessionSubtitlePreference)
    }

    func testAPickMadeInThePlayerIsNotOverwrittenByTheRememberedOne() async {
        let leaving = makeViewModel()
        leaving.sessionSubtitlePreference = .init(language: "eng", displayTitle: "English SDH", isExternal: false)
        await leaving.beginStop(reason: .userStop).value

        let current = makeViewModel()
        current.sessionSubtitlePreference = .init(language: "fra", displayTitle: "French", isExternal: false)
        current.setCurrentItem(makeItem())

        XCTAssertEqual(current.sessionSubtitlePreference?.displayTitle, "French")
    }

    // MARK: - Helpers

    private func makeViewModel() -> PlayerViewModel {
        let viewModel = PlayerViewModel(client: JellyfinClient(), reporter: SilentReporter())
        viewModel.currentItem = makeItem()
        return viewModel
    }

    private var streams: [MediaStream] {
        [
            stream(type: "Audio", codec: "eac3", language: "eng", title: "English", index: 1),
            stream(type: "Audio", codec: "aac", language: "jpn", title: "Japanese", index: 2),
            stream(type: "Subtitle", codec: "subrip", language: "eng", title: "English SDH", index: 3),
            stream(type: "Subtitle", codec: "PGSSUB", language: "eng", title: "English PGS", index: 4)
        ]
    }

    private func stream(type: String, codec: String, language: String, title: String, index: Int) -> MediaStream {
        MediaStream(
            type: type, codec: codec, language: language, displayTitle: title,
            title: nil, height: nil, width: nil, channels: nil, index: index, isDefault: nil,
            isExternal: false, isForced: nil, videoRangeType: nil, bitRate: nil,
            deliveryUrl: nil, deliveryMethod: nil
        )
    }

    private func makeItem() -> BaseItemDto {
        BaseItemDto(
            id: itemID, name: "Movie", type: .movie, seriesName: nil, seriesId: nil,
            seasonId: nil, parentId: nil, indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil, backdropImageTags: nil,
            parentBackdropImageTags: nil, primaryImageAspectRatio: nil, mediaType: nil,
            libraryName: "Movies", productionYear: 1985, communityRating: nil, officialRating: nil,
            genres: nil, taglines: nil, people: nil, criticRating: nil, premiereDate: nil, chapters: nil,
            path: nil, remoteTrailers: nil, localTrailerCount: nil, mediaStreams: nil
        )
    }
}

/// Accepts every report and does nothing: these tests are about tracks.
private final class SilentReporter: PlayerPlaybackReporting {
    func reset() {}
    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {}
    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {}
    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {}
    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {}
}
