import XCTest
@testable import Sashimi

/// How one stream reads on its card and in Details.
final class ServerDashboardSessionTests: XCTestCase {
    private func session(paused: Bool = false, transcoding: DashboardTranscodingInfo? = nil, client: String? = "Jellyfin Web") -> DashboardSession {
        DashboardSession(
            id: "s1",
            userName: "ozzy",
            client: client,
            applicationVersion: "10.11.0",
            deviceName: "Fire TV",
            supportsRemoteControl: true,
            nowPlayingItem: DashboardNowPlaying(
                id: "ep", name: "Mercy", type: "Episode", seriesName: "Vikings", seriesId: "series",
                parentIndexNumber: 4, indexNumber: 2, runTimeTicks: 26_920_000_000, container: "mkv",
                mediaStreams: [
                    DashboardMediaStream(type: "Video", codec: "hevc", width: 3840, height: 2160, videoRangeType: "HDR10",
                                         bitRate: 40_000_000, index: 0, isDefault: true, displayTitle: "4K HEVC HDR10"),
                    DashboardMediaStream(type: "Audio", codec: "dts", width: nil, height: nil, videoRangeType: nil,
                                         bitRate: 1_500_000, index: 1, isDefault: true, displayTitle: "English - DTS - 5.1")
                ]
            ),
            playState: DashboardPlayState(positionTicks: 11_100_000_000, isPaused: paused, playMethod: nil, audioStreamIndex: nil),
            transcodingInfo: transcoding
        )
    }

    private let videoTranscode = DashboardTranscodingInfo(
        audioCodec: "aac", videoCodec: "h264", container: "ts", isVideoDirect: false, isAudioDirect: false,
        bitrate: 8_000_000, width: 1920, height: 1080, hardwareAccelerationType: "qsv",
        transcodeReasons: ["ContainerBitrateExceedsLimit"]
    )

    func testBadgeWords() {
        XCTAssertEqual(PlayMode.directPlay.title, "Direct play")
        XCTAssertEqual(PlayMode.convertingAudio.title, "Converting audio")
        XCTAssertEqual(PlayMode.convertingVideo.title, "Converting video")
    }

    func testViewerLine() {
        XCTAssertEqual(ServerDashboardLogic.viewerLine(session()), "ozzy · Fire TV")
    }

    func testEpisodeTitleAndPoster() {
        let item = session().nowPlayingItem
        XCTAssertEqual(item?.displayTitle, "Vikings · S4:E2 · Mercy")
        XCTAssertEqual(item?.posterItemIds, ["series", "ep"], "series poster first")
    }

    func testDetailsDescribeTheConversion() {
        let rows = ServerDashboardLogic.detailRows(for: session(transcoding: videoTranscode))
        let byLabel = Dictionary(uniqueKeysWithValues: rows.map { ($0.label, $0.value) })
        XCTAssertEqual(byLabel["Viewer"], "ozzy")
        XCTAssertEqual(byLabel["App"], "Jellyfin Web 10.11.0")
        XCTAssertEqual(byLabel["Playing"], "Vikings · S4:E2 · Mercy")
        XCTAssertEqual(byLabel["Progress"], "18:30 / 44:52")
        XCTAssertEqual(byLabel["Play mode"], "Converting video")
        XCTAssertEqual(byLabel["Why"], "Bitrate cap")
        XCTAssertEqual(byLabel["Source video"], "4K HEVC HDR10")
        XCTAssertEqual(byLabel["Source audio"], "English - DTS - 5.1")
        XCTAssertEqual(byLabel["Sent as"], "TS · H264 · AAC")
        XCTAssertEqual(byLabel["Hardware"], "QSV")
        XCTAssertEqual(byLabel["Bitrate"], "8 Mbps")
    }

    func testDirectPlayDetailsHaveNoConversionRows() {
        let labels = ServerDashboardLogic.detailRows(for: session()).map(\.label)
        XCTAssertFalse(labels.contains("Why"))
        XCTAssertFalse(labels.contains("Sent as"))
        XCTAssertFalse(labels.contains("Hardware"))
        XCTAssertEqual(ServerDashboardLogic.detailRows(for: session()).first { $0.label == "Bitrate" }?.value, "42 Mbps")
    }

    func testHardwareIsNamedOnlyWhenVideoIsConverted() {
        let audioOnly = DashboardTranscodingInfo(
            audioCodec: "aac", videoCodec: "hevc", container: "mp4", isVideoDirect: true, isAudioDirect: false,
            bitrate: 40_000_000, width: 3840, height: 2160, hardwareAccelerationType: "qsv", transcodeReasons: []
        )
        XCTAssertFalse(ServerDashboardLogic.detailRows(for: session(transcoding: audioOnly)).map(\.label).contains("Hardware"))
    }

    func testDetailsNeverCarryAnAddress() {
        let rows = ServerDashboardLogic.detailRows(for: session(client: "Kodi 192.168.86.20"))
        XCTAssertEqual(rows.first { $0.label == "App" }?.value, "Kodi 192.x.x.x 10.11.0")
    }
}
