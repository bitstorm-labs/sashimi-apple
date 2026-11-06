import XCTest
@testable import Sashimi

/// The detail-page audio language chip (#828): the language that will play,
/// plus how many other audio languages the file has.
final class AudioLanguageChipTests: XCTestCase {
    private func audio(_ language: String?, index: Int, isDefault: Bool = false) -> MediaStream {
        MediaStream(
            type: "Audio",
            codec: "eac3",
            language: language,
            displayTitle: nil,
            title: nil,
            height: nil,
            width: nil,
            channels: 6,
            index: index,
            isDefault: isDefault,
            isExternal: false,
            isForced: false,
            videoRangeType: nil,
            bitRate: nil,
            deliveryUrl: nil,
            deliveryMethod: nil
        )
    }

    private func subtitle(_ language: String, index: Int) -> MediaStream {
        MediaStream(
            type: "Subtitle", codec: "subrip", language: language, displayTitle: nil, title: nil,
            height: nil, width: nil, channels: nil, index: index, isDefault: false, isExternal: false,
            isForced: false, videoRangeType: nil, bitRate: nil, deliveryUrl: nil, deliveryMethod: nil
        )
    }

    /// Love is Blind S11E09 as shipped: Portuguese dub flagged default, English second.
    private var dubbedDefault: [MediaStream] {
        [audio("por", index: 1, isDefault: true), audio("eng", index: 2), subtitle("eng", index: 3)]
    }

    func testPreferredLanguageWinsWhenTheFileHasIt() {
        let chip = PlaybackSelection.audioLanguageChip(
            streams: dubbedDefault, defaultAudioStreamIndex: nil, preferredLanguage: "en"
        )
        XCTAssertEqual(chip, .init(languageCode: "eng", otherLanguageCount: 1))
    }

    func testPreferredLanguageMissingFallsBackToTheFileDefault() {
        let chip = PlaybackSelection.audioLanguageChip(
            streams: dubbedDefault, defaultAudioStreamIndex: nil, preferredLanguage: "ja"
        )
        XCTAssertEqual(chip, .init(languageCode: "por", otherLanguageCount: 1))
    }

    func testUnsetPreferenceUsesTheFileDefault() {
        let chip = PlaybackSelection.audioLanguageChip(
            streams: dubbedDefault, defaultAudioStreamIndex: nil, preferredLanguage: ""
        )
        XCTAssertEqual(chip, .init(languageCode: "por", otherLanguageCount: 1))
    }

    func testServerDefaultIndexBeatsTheDefaultFlag() {
        let chip = PlaybackSelection.audioLanguageChip(
            streams: dubbedDefault, defaultAudioStreamIndex: 2, preferredLanguage: ""
        )
        XCTAssertEqual(chip?.languageCode, "eng")
    }

    func testNoDefaultFlagUsesTheFirstAudioStream() {
        let chip = PlaybackSelection.audioLanguageChip(
            streams: [audio("fra", index: 1), audio("eng", index: 2)],
            defaultAudioStreamIndex: nil, preferredLanguage: ""
        )
        XCTAssertEqual(chip?.languageCode, "fra")
    }

    func testThreeLetterPreferenceMatchesTwoLetterStreamCode() {
        let chip = PlaybackSelection.audioLanguageChip(
            streams: [audio("pt", index: 1, isDefault: true), audio("en", index: 2)],
            defaultAudioStreamIndex: nil, preferredLanguage: "eng"
        )
        XCTAssertEqual(chip, .init(languageCode: "en", otherLanguageCount: 1))
    }

    func testOthersCountDistinctLanguagesNotStreams() {
        // English main mix + commentary, plus two Portuguese mixes ("pt" and "por").
        let streams = [
            audio("eng", index: 1, isDefault: true),
            audio("eng", index: 2),
            audio("por", index: 3),
            audio("pt", index: 4),
        ]
        let chip = PlaybackSelection.audioLanguageChip(
            streams: streams, defaultAudioStreamIndex: nil, preferredLanguage: ""
        )
        XCTAssertEqual(chip, .init(languageCode: "eng", otherLanguageCount: 1))
    }

    func testSingleLanguageHasNoOthers() {
        let chip = PlaybackSelection.audioLanguageChip(
            streams: [audio("eng", index: 1, isDefault: true)],
            defaultAudioStreamIndex: nil, preferredLanguage: ""
        )
        XCTAssertEqual(chip, .init(languageCode: "eng", otherLanguageCount: 0))
    }

    func testNoChipWhenNoAudioStreamHasALanguage() {
        let streams = [audio(nil, index: 1, isDefault: true), audio("und", index: 2), subtitle("eng", index: 3)]
        XCTAssertNil(PlaybackSelection.audioLanguageChip(
            streams: streams, defaultAudioStreamIndex: nil, preferredLanguage: "en"
        ))
    }

    func testNoChipWhenThePlayingStreamHasNoLanguage() {
        // Claiming "English" for an untagged default track would be a guess.
        let streams = [audio(nil, index: 1, isDefault: true), audio("eng", index: 2)]
        XCTAssertNil(PlaybackSelection.audioLanguageChip(
            streams: streams, defaultAudioStreamIndex: nil, preferredLanguage: ""
        ))
    }

    func testChipText() {
        XCTAssertEqual(
            PlaybackSelection.AudioLanguageChip(languageCode: "eng", otherLanguageCount: 1)
                .text(locale: Locale(identifier: "en_US")),
            "English +1"
        )
        XCTAssertEqual(
            PlaybackSelection.AudioLanguageChip(languageCode: "por", otherLanguageCount: 0)
                .text(locale: Locale(identifier: "en_US")),
            "Portuguese"
        )
    }
}
