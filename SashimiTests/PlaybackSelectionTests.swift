import XCTest
@testable import Sashimi

final class PlaybackSelectionTests: XCTestCase {
    // MARK: - Helpers

    private func subtitleStream(
        language: String?,
        index: Int,
        isDefault: Bool? = nil,
        isExternal: Bool? = nil
    ) -> MediaStream {
        MediaStream(
            type: "Subtitle",
            codec: "subrip",
            language: language,
            displayTitle: language,
            title: nil,
            height: nil,
            width: nil,
            channels: nil,
            index: index,
            isDefault: isDefault,
            isExternal: isExternal
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
