import XCTest
@testable import Sashimi

final class PlaybackSelectionTests: XCTestCase {
    // MARK: - Helpers

    private func subtitleStream(
        language: String?,
        index: Int?,
        isDefault: Bool? = nil,
        isExternal: Bool? = nil,
        displayTitle: String? = nil
    ) -> MediaStream {
        MediaStream(
            type: "Subtitle",
            codec: "subrip",
            language: language,
            displayTitle: displayTitle ?? language,
            title: nil,
            height: nil,
            width: nil,
            channels: nil,
            index: index,
            isDefault: isDefault,
            isExternal: isExternal,
            videoRangeType: nil,
            bitRate: nil
        )
    }

    // MARK: - effectiveMaxBitrate

    func testSessionOverrideWinsOverSettings() {
        XCTAssertEqual(
            PlaybackSelection.effectiveMaxBitrate(sessionOverride: 8_000_000, settingsMaxBitrate: 20_000_000),
            8_000_000
        )
    }

    func testSettingsBitrateUsedWithoutOverride() {
        XCTAssertEqual(
            PlaybackSelection.effectiveMaxBitrate(sessionOverride: nil, settingsMaxBitrate: 20_000_000),
            20_000_000
        )
    }

    func testAutoSettingsBitrateMeansNoCap() {
        XCTAssertNil(PlaybackSelection.effectiveMaxBitrate(sessionOverride: nil, settingsMaxBitrate: 0))
    }

    // MARK: - languagesMatch

    func testMatchesIso639TwoVsThreeLetterCodes() {
        XCTAssertTrue(PlaybackSelection.languagesMatch("eng", "en"))
        XCTAssertTrue(PlaybackSelection.languagesMatch("en", "eng"))
        XCTAssertTrue(PlaybackSelection.languagesMatch("spa", "es"))
        XCTAssertTrue(PlaybackSelection.languagesMatch("fra", "fr"))
        XCTAssertTrue(PlaybackSelection.languagesMatch("jpn", "ja"))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(PlaybackSelection.languagesMatch("ENG", "en"))
        XCTAssertTrue(PlaybackSelection.languagesMatch("En", "eN"))
    }

    func testDifferentLanguagesDoNotMatch() {
        XCTAssertFalse(PlaybackSelection.languagesMatch("eng", "es"))
        XCTAssertFalse(PlaybackSelection.languagesMatch("fra", "de"))
    }

    func testNilOrEmptyCodesNeverMatch() {
        XCTAssertFalse(PlaybackSelection.languagesMatch(nil, "en"))
        XCTAssertFalse(PlaybackSelection.languagesMatch("en", nil))
        XCTAssertFalse(PlaybackSelection.languagesMatch(nil, nil))
        XCTAssertFalse(PlaybackSelection.languagesMatch("", "en"))
        XCTAssertFalse(PlaybackSelection.languagesMatch("en", ""))
    }

    func testUnmappableCodesFallBackToLiteralComparison() {
        XCTAssertTrue(PlaybackSelection.languagesMatch("und", "UND"))
        XCTAssertFalse(PlaybackSelection.languagesMatch("und", "en"))
    }

    // MARK: - preferredSubtitleStream

    func testNoSubtitleWhenDisabled() {
        let streams = [subtitleStream(language: "eng", index: 1, isDefault: true)]
        XCTAssertNil(
            PlaybackSelection.preferredSubtitleStream(from: streams, preferredLanguage: "en", subtitlesEnabled: false)
        )
    }

    func testNoSubtitleWhenNoStreams() {
        XCTAssertNil(
            PlaybackSelection.preferredSubtitleStream(from: [], preferredLanguage: "en", subtitlesEnabled: true)
        )
    }

    func testPreferredLanguageWinsOverDefaultFlag() {
        let streams = [
            subtitleStream(language: "fre", index: 1, isDefault: true),
            subtitleStream(language: "eng", index: 2)
        ]
        let selected = PlaybackSelection.preferredSubtitleStream(
            from: streams,
            preferredLanguage: "en",
            subtitlesEnabled: true
        )
        XCTAssertEqual(selected?.index, 2)
    }

    func testFallsBackToDefaultFlaggedStreamWhenLanguageUnavailable() {
        let streams = [
            subtitleStream(language: "fre", index: 1),
            subtitleStream(language: "ger", index: 2, isDefault: true)
        ]
        let selected = PlaybackSelection.preferredSubtitleStream(
            from: streams,
            preferredLanguage: "ja",
            subtitlesEnabled: true
        )
        XCTAssertEqual(selected?.index, 2)
    }

    func testFallsBackToFirstStreamWithoutDefaultFlag() {
        let streams = [
            subtitleStream(language: "fre", index: 3),
            subtitleStream(language: "ger", index: 4)
        ]
        let selected = PlaybackSelection.preferredSubtitleStream(
            from: streams,
            preferredLanguage: "",
            subtitlesEnabled: true
        )
        XCTAssertEqual(selected?.index, 3)
    }

    // MARK: - matchingSubtitleStream

    func testMatchesByLanguageWhenIndexesShift() {
        // Same track, but the new media source numbers its streams differently
        let streams = [
            subtitleStream(language: "fre", index: 4),
            subtitleStream(language: "eng", index: 7)
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "eng",
            displayTitle: "eng",
            isExternal: false
        )
        XCTAssertEqual(match?.index, 7)
    }

    func testMatchesToleratesTwoVsThreeLetterLanguageCodes() {
        let streams = [subtitleStream(language: "eng", index: 3)]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "en",
            displayTitle: nil,
            isExternal: false
        )
        XCTAssertEqual(match?.index, 3)
    }

    func testPrefersDisplayTitleMatchAmongSameLanguageStreams() {
        let streams = [
            subtitleStream(language: "eng", index: 2, displayTitle: "English"),
            subtitleStream(language: "eng", index: 3, displayTitle: "English (SDH)")
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "eng",
            displayTitle: "English (SDH)",
            isExternal: false
        )
        XCTAssertEqual(match?.index, 3)
    }

    func testPrefersMatchingExternalFlagWhenTitleDiffers() {
        let streams = [
            subtitleStream(language: "eng", index: 2, isExternal: false, displayTitle: "English (embedded)"),
            subtitleStream(language: "eng", index: 5, isExternal: true, displayTitle: "English (SRT)")
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "eng",
            displayTitle: "English",
            isExternal: true
        )
        XCTAssertEqual(match?.index, 5)
    }

    func testFallsBackToLanguageOnlyWhenExternalFlagDiffers() {
        let streams = [
            subtitleStream(language: "eng", index: 2, isExternal: false, displayTitle: "English")
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "eng",
            displayTitle: "English (SRT)",
            isExternal: true
        )
        XCTAssertEqual(match?.index, 2)
    }

    func testSkipsStreamsWithoutAnIndex() {
        // A stream with no index can't be addressed for playback — matching
        // it would previously collapse to index 0 and silently fail.
        let streams = [
            subtitleStream(language: "eng", index: nil),
            subtitleStream(language: "eng", index: 6)
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "eng",
            displayTitle: "eng",
            isExternal: false
        )
        XCTAssertEqual(match?.index, 6)
    }

    func testNoMatchWhenLanguageMissingFromNewSource() {
        let streams = [subtitleStream(language: "fre", index: 1)]
        XCTAssertNil(
            PlaybackSelection.matchingSubtitleStream(
                in: streams,
                language: "eng",
                displayTitle: "eng",
                isExternal: false
            )
        )
    }

    func testNoMatchForNilLanguagePreference() {
        let streams = [subtitleStream(language: "eng", index: 1)]
        XCTAssertNil(
            PlaybackSelection.matchingSubtitleStream(
                in: streams,
                language: nil,
                displayTitle: "Unknown",
                isExternal: false
            )
        )
    }

    // MARK: - preferredAudioOptionIndex

    func testAudioIndexMatchesPreferredLanguage() {
        // AVFoundation reports two-letter codes; the setting stores two-letter too
        let codes: [String?] = ["ja", "en", "es"]
        XCTAssertEqual(PlaybackSelection.preferredAudioOptionIndex(languageCodes: codes, preferredLanguage: "en"), 1)
    }

    func testAudioIndexNilWithoutPreference() {
        XCTAssertNil(PlaybackSelection.preferredAudioOptionIndex(languageCodes: ["en"], preferredLanguage: ""))
    }

    func testAudioIndexNilWhenNoMatch() {
        let codes: [String?] = ["ja", nil, "es"]
        XCTAssertNil(PlaybackSelection.preferredAudioOptionIndex(languageCodes: codes, preferredLanguage: "de"))
    }
}
