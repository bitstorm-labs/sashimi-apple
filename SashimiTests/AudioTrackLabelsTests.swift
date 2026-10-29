import XCTest
@testable import Sashimi

/// #808: two audio tracks both listed as "English". Colliding names gain the
/// Title, then codec and channels; unique names are left alone.
final class AudioTrackLabelsTests: XCTestCase {
    private typealias Details = AudioTrackLabels.Details

    func testUniqueNamesAreUnchanged() {
        let labels = AudioTrackLabels.labels(
            names: ["English", "Japanese"],
            details: [Details(codec: "ac3", channels: 6), Details(title: "Commentary", codec: "aac", channels: 2)]
        )
        XCTAssertEqual(labels, ["English", "Japanese"])
    }

    func testCodecAndChannelsTellSameNamedTracksApart() {
        let labels = AudioTrackLabels.labels(
            names: ["English", "English"],
            details: [Details(codec: "ac3", channels: 6), Details(codec: "aac", channels: 2)]
        )
        XCTAssertEqual(labels, ["English · AC3 5.1", "English · AAC Stereo"])
    }

    func testTitleAloneIsUsedWhenItIsEnough() {
        let labels = AudioTrackLabels.labels(
            names: ["English", "English"],
            details: [Details(codec: "aac", channels: 2), Details(title: "Commentary", codec: "aac", channels: 2)]
        )
        XCTAssertEqual(labels, ["English", "English · Commentary"])
    }

    func testTitleAndFormatTogetherWhenTheTitleIsNotEnough() {
        let labels = AudioTrackLabels.labels(
            names: ["English", "English", "English"],
            details: [
                Details(codec: "truehd", channels: 8),
                Details(codec: "ac3", channels: 6),
                Details(title: "Commentary", codec: "aac", channels: 2)
            ]
        )
        XCTAssertEqual(labels, ["English · TrueHD 7.1", "English · AC3 5.1", "English · Commentary · AAC Stereo"])
    }

    func testOnlyTheCollidingTracksChange() {
        let labels = AudioTrackLabels.labels(
            names: ["English", "French", "English"],
            details: [Details(codec: "eac3", channels: 6), Details(codec: "ac3", channels: 6), Details(codec: "aac", channels: 1)]
        )
        XCTAssertEqual(labels, ["English · E-AC3 5.1", "French", "English · AAC Mono"])
    }

    func testIdenticalTracksFallBackToTheirTrackNumber() {
        let labels = AudioTrackLabels.labels(
            names: ["English", "English"],
            details: [Details(codec: "aac", channels: 2), Details(codec: "aac", channels: 2)]
        )
        XCTAssertEqual(labels, ["English · AAC Stereo · Track 1", "English · AAC Stereo · Track 2"])
    }

    func testNothingKnownStillGivesDistinctLabels() {
        let labels = AudioTrackLabels.labels(names: ["English", "English"], details: [])
        XCTAssertEqual(labels, ["English · Track 1", "English · Track 2"])
    }

    func testATitleTheNameAlreadyCarriesIsNotRepeated() {
        let labels = AudioTrackLabels.labels(
            names: ["English", "English"],
            details: [Details(title: "English", codec: "ac3", channels: 6), Details(codec: "aac", channels: 2)]
        )
        XCTAssertEqual(labels, ["English · AC3 5.1", "English · AAC Stereo"])
    }

    /// The file from the 1.6.73 Mac check: two English E-AC3 5.1 tracks,
    /// one of them Atmos.
    func testAtmosTellsTwoEAC3TracksApart() {
        let labels = AudioTrackLabels.labels(
            names: ["English", "English"],
            details: [
                Details(codec: "eac3", profile: "Dolby Digital Plus + Dolby Atmos", channels: 6),
                Details(codec: "eac3", channels: 6)
            ]
        )
        XCTAssertEqual(labels, ["English · E-AC3 Atmos 5.1", "English · E-AC3 5.1"])
    }

    func testProfilesNameTheFormat() {
        XCTAssertEqual(AudioTrackLabels.formatName(codec: "dts", profile: "DTS-HD MA"), "DTS-HD MA")
        XCTAssertEqual(AudioTrackLabels.formatName(codec: "dts", profile: "DTS:X"), "DTS:X")
        XCTAssertEqual(AudioTrackLabels.formatName(codec: "truehd", profile: "Dolby TrueHD + Dolby Atmos"), "TrueHD Atmos")
        XCTAssertEqual(AudioTrackLabels.formatName(codec: "dts", profile: nil), "DTS")
    }

    func testMenuLabelDefaultsToTheDisplayNameAndSelectionNameIsKept() {
        let tracks = [
            AudioTrackOption(id: "0", displayName: "English", languageCode: "en", index: 0),
            AudioTrackOption(id: "1", displayName: "English", languageCode: "en", index: 1)
        ]
        XCTAssertEqual(tracks[0].menuLabel, "English")
        let labelled = AudioTrackLabels.labelled(tracks, details: [Details(codec: "ac3", channels: 6), Details(title: "Commentary")])
        XCTAssertEqual(labelled.map(\.menuLabel), ["English", "English · Commentary"])
        XCTAssertEqual(labelled.map(\.displayName), ["English", "English"])
    }

    // MARK: Server streams against AVPlayer's options

    func testServerStreamsLineUpWhenCountAndLanguagesAgree() {
        let streams = [stream(language: "eng", index: 1), stream(language: "jpn", index: 2)]
        XCTAssertTrue(AudioTrackLabels.streamsMatch(streams, languages: ["en", "ja"]))
        XCTAssertTrue(AudioTrackLabels.streamsMatch(streams, languages: [nil, "ja"]))
        XCTAssertTrue(AudioTrackLabels.streamsMatch([stream(language: "und", index: 1)], languages: ["en"]))
    }

    func testServerStreamsAreIgnoredWhenTheyDisagree() {
        let streams = [stream(language: "eng", index: 1), stream(language: "jpn", index: 2)]
        XCTAssertFalse(AudioTrackLabels.streamsMatch(streams, languages: ["ja", "en"]))
        XCTAssertFalse(AudioTrackLabels.streamsMatch(streams, languages: ["en"]))
        XCTAssertFalse(AudioTrackLabels.streamsMatch([], languages: []))
    }

    // MARK: The player's Audio menu (transcoded playback lists the server's streams)

    @MainActor
    func testServerSideAudioMenuDisambiguatesTwoEnglishTracks() async throws {
        let viewModel = PlayerViewModel()
        viewModel.currentMediaSource = try JSONDecoder().decode(MediaSourceInfo.self, from: Data("""
        {"Id":"m1","TranscodingUrl":"/videos/m1/master.m3u8","MediaStreams":[
          {"Type":"Video","Index":0,"Codec":"h264"},
          {"Type":"Audio","Index":1,"Codec":"eac3","Profile":"Dolby Digital Plus + Dolby Atmos","Language":"eng","DisplayTitle":"English","Channels":6},
          {"Type":"Audio","Index":2,"Codec":"aac","Language":"eng","DisplayTitle":"English","Channels":2},
          {"Type":"Audio","Index":3,"Codec":"aac","Language":"jpn","DisplayTitle":"Japanese","Channels":2}
        ]}
        """.utf8))
        viewModel.loadAudioTracks()
        for _ in 0..<200 where viewModel.audioTracks.isEmpty {
            await Task.yield()
        }
        XCTAssertEqual(viewModel.audioTracks.map(\.menuLabel), ["English · E-AC3 Atmos 5.1", "English · AAC Stereo", "Japanese"])
        XCTAssertEqual(viewModel.audioTracks.map(\.displayName), ["English", "English", "Japanese"])
    }

    private func stream(language: String, index: Int) -> MediaStream {
        MediaStream(
            type: "Audio", codec: "aac", language: language, displayTitle: nil,
            title: nil, height: nil, width: nil, channels: 2, index: index, isDefault: nil,
            isExternal: false, isForced: nil, videoRangeType: nil, bitRate: nil,
            deliveryUrl: nil, deliveryMethod: nil
        )
    }
}
