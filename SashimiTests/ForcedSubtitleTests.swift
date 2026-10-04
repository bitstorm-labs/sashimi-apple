import XCTest
@testable import Sashimi

/// Forced subtitle tracks (#603). Stream layouts are taken from real files on
/// the home server: "Warfare" lists English Forced at index 3 before the full
/// English track; "Batman Ninja vs. Yakuza League" has Japanese audio with an
/// English Forced track.
final class ForcedSubtitleTests: XCTestCase {
    private func subtitle(
        _ index: Int,
        language: String?,
        forced: Bool = false,
        isDefault: Bool = false,
        displayTitle: String? = nil,
        codec: String = "subrip"
    ) -> MediaStream {
        MediaStream(
            type: "Subtitle", codec: codec, language: language,
            displayTitle: displayTitle, title: nil, height: nil, width: nil,
            channels: nil, index: index, isDefault: isDefault, isExternal: false,
            isForced: forced, videoRangeType: nil, bitRate: nil,
            deliveryUrl: nil, deliveryMethod: nil
        )
    }

    private var warfare: [MediaStream] {
        [
            subtitle(3, language: "eng", forced: true, displayTitle: "Forced - English - SUBRIP"),
            subtitle(4, language: "eng", displayTitle: "English - SUBRIP"),
            subtitle(5, language: "eng", displayTitle: "SDH - English - Hearing Impaired - SUBRIP"),
            subtitle(20, language: "deu", displayTitle: "German - SUBRIP")
        ]
    }

    // MARK: Subtitles on

    func testPreferredLanguagePicksTheFullTrackOverAForcedOneListedFirst() {
        let picked = PlaybackSelection.preferredSubtitleStream(
            from: warfare, preferredLanguage: "en", subtitlesEnabled: true, audioLanguage: "eng"
        )
        XCTAssertEqual(picked?.index, 4, "a forced track carries a handful of lines, never the full subtitles")
    }

    func testForcedTrackStillUsedWhenItIsTheOnlyOneInThePreferredLanguage() {
        let streams = [subtitle(3, language: "eng", forced: true), subtitle(4, language: "fre")]
        let picked = PlaybackSelection.preferredSubtitleStream(
            from: streams, preferredLanguage: "en", subtitlesEnabled: true, audioLanguage: "eng"
        )
        XCTAssertEqual(picked?.index, 3)
    }

    func testNoPreferredMatchFallsBackToForcedTrackInTheAudioLanguage() {
        let picked = PlaybackSelection.preferredSubtitleStream(
            from: warfare, preferredLanguage: "ja", subtitlesEnabled: true, audioLanguage: "eng"
        )
        XCTAssertEqual(picked?.index, 3)
    }

    func testNoPreferredMatchAndNoForcedTrackKeepsTheFullTrackFallback() {
        let streams = [subtitle(3, language: "fre"), subtitle(4, language: "ger", isDefault: true)]
        let picked = PlaybackSelection.preferredSubtitleStream(
            from: streams, preferredLanguage: "ja", subtitlesEnabled: true, audioLanguage: "eng"
        )
        XCTAssertEqual(picked?.index, 4)
    }

    // MARK: Subtitles off

    func testSubtitlesOffStillShowsTheForcedTrackForTheAudioLanguage() {
        let picked = PlaybackSelection.preferredSubtitleStream(
            from: warfare, preferredLanguage: "en", subtitlesEnabled: false, audioLanguage: "eng"
        )
        XCTAssertEqual(picked?.index, 3, "foreign-dialogue lines show with subtitles off, as in every standard player")
    }

    func testSubtitlesOffIgnoresAForcedTrackInAnotherLanguage() {
        // Japanese audio; the forced track is for the English dub.
        let streams = [
            subtitle(3, language: "eng", forced: true),
            subtitle(4, language: "eng", isDefault: true)
        ]
        XCTAssertNil(PlaybackSelection.preferredSubtitleStream(
            from: streams, preferredLanguage: "en", subtitlesEnabled: false, audioLanguage: "jpn"
        ))
    }

    func testSubtitlesOffWithoutAForcedTrackShowsNothing() {
        let streams = [subtitle(4, language: "eng", isDefault: true)]
        XCTAssertNil(PlaybackSelection.preferredSubtitleStream(
            from: streams, preferredLanguage: "en", subtitlesEnabled: false, audioLanguage: "eng"
        ))
    }

    func testSubtitlesOffNeverAutoSelectsAnImageForcedTrack() {
        // A forced PGS track would need a burn-in re-encode (#595).
        let streams = [subtitle(3, language: "eng", forced: true, codec: "PGSSUB")]
        XCTAssertNil(PlaybackSelection.preferredSubtitleStream(
            from: streams, preferredLanguage: "", subtitlesEnabled: false, audioLanguage: "eng"
        ))
    }

    // MARK: Menu labels

    func testForcedTrackWithoutAServerLabelIsMarked() {
        XCTAssertEqual(
            PlaybackSelection.subtitleDisplayName(for: subtitle(3, language: "eng", forced: true)),
            "eng (Forced)"
        )
        XCTAssertEqual(
            PlaybackSelection.subtitleDisplayName(for: subtitle(3, language: "eng", forced: true, displayTitle: "English")),
            "English (Forced)"
        )
    }

    func testServerLabelThatAlreadySaysForcedIsLeftAlone() {
        XCTAssertEqual(
            PlaybackSelection.subtitleDisplayName(for: warfare[0]),
            "Forced - English - SUBRIP"
        )
    }

    func testFullTrackLabelIsUnchanged() {
        XCTAssertEqual(PlaybackSelection.subtitleDisplayName(for: warfare[1]), "English - SUBRIP")
        XCTAssertEqual(PlaybackSelection.subtitleDisplayName(for: subtitle(9, language: nil)), "Unknown")
    }

    func testSessionPickOfAMarkedForcedTrackStillMatchesByTitle() {
        let streams = [
            subtitle(3, language: "eng", forced: true, displayTitle: "English"),
            subtitle(4, language: "eng", displayTitle: "English")
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams, language: "eng", displayTitle: "English (Forced)", isExternal: false
        )
        XCTAssertEqual(match?.index, 3)
    }
}
