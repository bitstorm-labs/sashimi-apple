import XCTest
@testable import Sashimi

/// The admin dashboard's decisions: how a stream plays and why, in plain
/// words; what it costs; what is redacted; what counts as a warning; who may
/// see it at all.
final class ServerDashboardLogicTests: XCTestCase {
    // MARK: - Fixtures

    private func transcoding(
        video: Bool,
        audio: Bool,
        reasons: [String] = [],
        audioCodec: String? = nil,
        width: Int? = nil,
        bitrate: Int? = nil
    ) -> DashboardTranscodingInfo {
        DashboardTranscodingInfo(
            audioCodec: audioCodec,
            videoCodec: nil,
            container: nil,
            isVideoDirect: video,
            isAudioDirect: audio,
            bitrate: bitrate,
            width: width,
            height: nil,
            hardwareAccelerationType: nil,
            transcodeReasons: reasons
        )
    }

    private func stream(
        _ type: String,
        codec: String? = nil,
        width: Int? = nil,
        range: String? = nil,
        bitRate: Int? = nil,
        index: Int? = nil,
        isDefault: Bool = false
    ) -> DashboardMediaStream {
        DashboardMediaStream(
            type: type,
            codec: codec,
            width: width,
            height: nil,
            videoRangeType: range,
            bitRate: bitRate,
            index: index,
            isDefault: isDefault,
            displayTitle: nil
        )
    }

    private func session(
        streams: [DashboardMediaStream],
        transcoding: DashboardTranscodingInfo?,
        audioIndex: Int? = nil
    ) -> DashboardSession {
        DashboardSession(
            id: "s1",
            userName: "mom",
            client: "Sashimi",
            applicationVersion: nil,
            deviceName: "Roku",
            supportsRemoteControl: true,
            nowPlayingItem: DashboardNowPlaying(
                id: "i1",
                name: "300",
                type: "Movie",
                seriesName: nil,
                seriesId: nil,
                parentIndexNumber: nil,
                indexNumber: nil,
                runTimeTicks: 70_200_000_000,
                container: "mkv",
                mediaStreams: streams
            ),
            playState: DashboardPlayState(positionTicks: 12_440_000_000, isPaused: false, playMethod: "Transcode", audioStreamIndex: audioIndex),
            transcodingInfo: transcoding
        )
    }

    // MARK: - Badge truth table

    func testNoTranscodingInfoIsDirectPlay() {
        XCTAssertEqual(ServerDashboardLogic.playMode(nil), .directPlay)
    }

    func testBothDirectIsDirectPlay() {
        XCTAssertEqual(ServerDashboardLogic.playMode(transcoding(video: true, audio: true)), .directPlay)
    }

    func testVideoCopiedAudioConvertedIsConvertingAudio() {
        XCTAssertEqual(ServerDashboardLogic.playMode(transcoding(video: true, audio: false)), .convertingAudio)
    }

    func testVideoTranscodedIsConvertingVideo() {
        XCTAssertEqual(ServerDashboardLogic.playMode(transcoding(video: false, audio: true)), .convertingVideo)
        XCTAssertEqual(ServerDashboardLogic.playMode(transcoding(video: false, audio: false)), .convertingVideo)
    }

    func testSubtitleBurnInIsConvertingVideoEvenWhenFlagsSayDirect() {
        let info = transcoding(video: true, audio: true, reasons: ["SubtitleCodecNotSupported"])
        XCTAssertEqual(ServerDashboardLogic.playMode(info), .convertingVideo)
    }

    func testMissingVideoFlagIsTreatedAsConverting() throws {
        let json = #"{"IsAudioDirect":true,"TranscodeReasons":[]}"#
        let info = try JSONDecoder().decode(DashboardTranscodingInfo.self, from: Data(json.utf8))
        XCTAssertEqual(ServerDashboardLogic.playMode(info), .convertingVideo)
    }

    // MARK: - Plain words

    func testKnownReasonsReadAsPlainWords() {
        XCTAssertEqual(
            ServerDashboardLogic.plainReasons(["ContainerBitrateExceedsLimit", "AudioCodecNotSupported", "SubtitleCodecNotSupported"]),
            ["Bitrate cap", "Audio format not supported", "Subtitles burned in"]
        )
    }

    func testUnknownReasonIsDeCamelCasedNeverRaw() {
        XCTAssertEqual(ServerDashboardLogic.plainReasons(["FooBarNotSupported"]), ["Foo bar not supported"])
    }

    func testDuplicateReasonWordsAppearOnce() {
        XCTAssertEqual(
            ServerDashboardLogic.plainReasons(["ContainerBitrateExceedsLimit", "VideoBitrateNotSupported"]),
            ["Bitrate cap"]
        )
    }

    // MARK: - Detail line

    func testDirectPlayDetailIsTheSourceFormat() {
        let item = session(streams: [stream("Video", codec: "hevc", width: 3840, range: "DOVIWithHDR10")], transcoding: nil)
        XCTAssertEqual(ServerDashboardLogic.detailLine(for: item), "4K Dolby Vision")
    }

    func testRemuxDetailSaysRemux() {
        let item = session(
            streams: [stream("Video", codec: "h264", width: 1920, range: "SDR")],
            transcoding: transcoding(video: true, audio: true, reasons: ["ContainerNotSupported"])
        )
        XCTAssertEqual(ServerDashboardLogic.detailLine(for: item), "1080p · Remux")
    }

    func testConvertingAudioDetailNamesBothCodecs() {
        let item = session(
            streams: [stream("Video", width: 3840, range: "HDR10"), stream("Audio", codec: "dts", index: 1)],
            transcoding: transcoding(video: true, audio: false, reasons: ["AudioCodecNotSupported"], audioCodec: "ac3")
        )
        XCTAssertEqual(ServerDashboardLogic.detailLine(for: item), "4K HDR10 · Video copied · DTS → AC3 · Audio format not supported")
    }

    func testConvertingAudioUsesTheSelectedAudioTrack() {
        let item = session(
            streams: [stream("Video", width: 1920), stream("Audio", codec: "aac", index: 1), stream("Audio", codec: "truehd", index: 2)],
            transcoding: transcoding(video: true, audio: false, audioCodec: "eac3"),
            audioIndex: 2
        )
        XCTAssertEqual(ServerDashboardLogic.detailLine(for: item), "1080p · Video copied · TRUEHD → EAC3")
    }

    func testConvertingVideoListsEveryReasonAndTheResolutionDrop() {
        let item = session(
            streams: [stream("Video", width: 3840, range: "SDR")],
            transcoding: transcoding(video: false, audio: true, reasons: ["ContainerBitrateExceedsLimit", "VideoRangeTypeNotSupported"], width: 1920)
        )
        XCTAssertEqual(ServerDashboardLogic.detailLine(for: item), "4K · Bitrate cap, HDR not supported · 4K → 1080p")
    }

    // MARK: - Bitrate

    func testTranscodedBitrateIsTheTranscodesRate() {
        let item = session(streams: [stream("Video", bitRate: 60_000_000)], transcoding: transcoding(video: false, audio: true, bitrate: 8_000_000))
        XCTAssertEqual(ServerDashboardLogic.bitrate(of: item), 8_000_000)
    }

    func testDirectPlayBitrateIsVideoPlusSelectedAudio() {
        let item = session(
            streams: [stream("Video", bitRate: 9_747_755), stream("Audio", bitRate: 640_000, index: 1, isDefault: true), stream("Audio", bitRate: 1_500_000, index: 2)],
            transcoding: nil
        )
        XCTAssertEqual(ServerDashboardLogic.bitrate(of: item), 10_387_755)
    }

    func testTotalBitrateSumsEverySession() {
        let one = session(streams: [], transcoding: transcoding(video: false, audio: true, bitrate: 8_000_000))
        let two = session(streams: [], transcoding: transcoding(video: true, audio: false, bitrate: 38_000_000))
        XCTAssertEqual(ServerDashboardLogic.totalBitrate([one, two]), 46_000_000)
    }

    func testBitrateFormatting() {
        XCTAssertEqual(ServerDashboardLogic.formatBitrate(61_200_000), "61 Mbps")
        XCTAssertEqual(ServerDashboardLogic.formatBitrate(8_400_000), "8.4 Mbps")
        XCTAssertEqual(ServerDashboardLogic.formatBitrate(640_000), "640 kbps")
    }

    // MARK: - Redaction

    func testIPv4KeepsOnlyTheFirstOctet() {
        XCTAssertEqual(ServerDashboardLogic.redactIPs("IP address: 185.220.101.4"), "IP address: 185.x.x.x")
    }

    func testIPv6KeepsOnlyTheFirstGroup() {
        XCTAssertEqual(ServerDashboardLogic.redactIPs("from 2001:db8:85a3::8a2e:370:7334 now"), "from 2001:x:x now")
    }

    func testTextWithoutAddressesIsUnchanged() {
        XCTAssertEqual(ServerDashboardLogic.redactIPs("mondo is playing 300 at 10:30"), "mondo is playing 300 at 10:30")
        XCTAssertEqual(ServerDashboardLogic.redactIPs("started 10:30:15 ok"), "started 10:30:15 ok", "a clock time is not an address")
    }

    func testProgressReadsAsClockTimes() {
        XCTAssertEqual(ServerDashboardLogic.progressText(positionTicks: 34_900_000_000, runTimeTicks: 56_400_000_000), "58:10 / 1:34:00")
        XCTAssertNil(ServerDashboardLogic.progressText(positionTicks: 10, runTimeTicks: nil))
        XCTAssertEqual(ServerDashboardLogic.progressFraction(positionTicks: 25, runTimeTicks: 100), 0.25)
        XCTAssertEqual(ServerDashboardLogic.progressFraction(positionTicks: 200, runTimeTicks: 100), 1, "clamped")
    }

    func testFailedSignInRowIsRedRedactedAndShowsTheOverview() {
        let entry = ActivityLogEntry(
            id: 1,
            name: "Failed login attempt from admin",
            shortOverview: "IP address: 185.220.101.4",
            type: "AuthenticationFailed",
            date: Date(timeIntervalSince1970: 0),
            severity: "Error"
        )
        let row = ServerDashboardLogic.activityRow(entry, now: Date(timeIntervalSince1970: 7_200))
        XCTAssertEqual(row.tone, .failure)
        XCTAssertEqual(row.text, "Failed login attempt from admin · 185.x.x.x")
        XCTAssertEqual(row.when, "2 h")
        XCTAssertFalse(row.text.contains("220"))
    }

    func testAnErrorSeverityEntryIsRedWhateverItsType() {
        let entry = ActivityLogEntry(
            id: 3, name: "Subtitles could not be downloaded", shortOverview: nil,
            type: "SubtitleDownloadFailure", date: Date(timeIntervalSince1970: 0), severity: "Error"
        )
        XCTAssertEqual(ServerDashboardLogic.activityRow(entry, now: Date(timeIntervalSince1970: 30)).tone, .failure)
    }

    func testPluginVersionOverviewIsNotShown() {
        let entry = ActivityLogEntry(
            id: 2, name: "TheIntroDB was installed", shortOverview: "Version 1.2.0.0",
            type: "PluginInstalled", date: Date(timeIntervalSince1970: 0), severity: "Information"
        )
        XCTAssertEqual(ServerDashboardLogic.activityRow(entry, now: Date(timeIntervalSince1970: 30)).text, "TheIntroDB was installed")
    }

    func testRelativeTimes() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(ServerDashboardLogic.relativeTime(now.addingTimeInterval(-20), now: now), "now")
        XCTAssertEqual(ServerDashboardLogic.relativeTime(now.addingTimeInterval(-12 * 60), now: now), "12 min")
        XCTAssertEqual(ServerDashboardLogic.relativeTime(now.addingTimeInterval(-5 * 3_600), now: now), "5 h")
        XCTAssertEqual(ServerDashboardLogic.relativeTime(now.addingTimeInterval(-3 * 86_400), now: now), "3 d")
    }
}

/// Storage, health, "Needs attention", the gate and the live response shapes.
final class ServerDashboardHealthTests: XCTestCase {
    private func transcoding(video: Bool, audio: Bool) -> DashboardTranscodingInfo {
        DashboardTranscodingInfo(
            audioCodec: nil, videoCodec: nil, container: nil, isVideoDirect: video, isAudioDirect: audio,
            bitrate: nil, width: nil, height: nil, hardwareAccelerationType: nil, transcodeReasons: []
        )
    }

    private func session(transcoding: DashboardTranscodingInfo?) -> DashboardSession {
        DashboardSession(
            id: "s1", userName: "ozzy", client: "Jellyfin Android TV", applicationVersion: nil, deviceName: "Fire TV",
            supportsRemoteControl: true, nowPlayingItem: nil, playState: nil, transcodingInfo: transcoding
        )
    }

    // MARK: - Storage

    func testStorageWarnsOnlyAboveEightyFivePercent() {
        XCTAssertFalse(ServerDashboardLogic.isStorageWarning(free: 15, used: 85))
        XCTAssertTrue(ServerDashboardLogic.isStorageWarning(free: 14, used: 86))
        XCTAssertFalse(ServerDashboardLogic.isStorageWarning(free: 0, used: 0), "an empty report is not a full disk")
    }

    func testMediaStorageCountsEachDriveOnce() throws {
        let json = #"""
        {"TranscodingTempFolder":{"FreeSpace":10,"UsedSpace":90,"DeviceId":"cache"},
         "Libraries":[
          {"Name":"Movies","Folders":[{"FreeSpace":100,"UsedSpace":300,"DeviceId":"array"},{"FreeSpace":100,"UsedSpace":300,"DeviceId":"array"}]},
          {"Name":"Shows","Folders":[{"FreeSpace":100,"UsedSpace":300,"DeviceId":"array"},{"FreeSpace":50,"UsedSpace":50,"DeviceId":"usb"}]}]}
        """#
        let storage = try JSONDecoder().decode(SystemStorageInfo.self, from: Data(json.utf8))
        let rows = ServerDashboardLogic.storageRows(storage)
        XCTAssertEqual(rows.map(\.title), ["Media storage", "Cache drive"])
        XCTAssertEqual(rows[0].tone, .ok)
        XCTAssertEqual(rows[0].value, "150 B free of 500 B")
        XCTAssertEqual(rows[1].tone, .warning, "90% used")
        XCTAssertEqual(rows[1].value, "90% full")
    }

    // MARK: - Health

    func testFailedTaskIsAFailureRowAndTheScanReadsOK() {
        let now = Date(timeIntervalSince1970: 100_000)
        let tasks = [
            ScheduledTaskInfo(name: "Scan Media Library", key: "RefreshLibrary", state: "Idle",
                              lastExecutionResult: .init(status: "Completed", endTimeUtc: now.addingTimeInterval(-7_200))),
            ScheduledTaskInfo(name: "Intro Skipper analysis", key: "Intro", state: "Idle",
                              lastExecutionResult: .init(status: "Failed", endTimeUtc: now.addingTimeInterval(-3_600))),
            ScheduledTaskInfo(name: "Clean Logs", key: "Clean", state: "Idle",
                              lastExecutionResult: .init(status: "Completed", endTimeUtc: now))
        ]
        let rows = ServerDashboardLogic.healthRows(tasks: tasks, storage: nil, encoding: nil, sessions: [], now: now)
        XCTAssertEqual(rows.map(\.title), ["Library scan", "Intro Skipper analysis"])
        XCTAssertEqual(rows[0].value, "OK · 2 h ago")
        XCTAssertEqual(rows[0].tone, .ok)
        XCTAssertEqual(rows[1].value, "Failed · 1 h ago")
        XCTAssertEqual(rows[1].tone, .failure)
    }

    func testFailedLibraryScanIsAFailure() {
        let now = Date(timeIntervalSince1970: 100_000)
        let tasks = [ScheduledTaskInfo(name: "Scan Media Library", key: "RefreshLibrary", state: "Idle",
                                       lastExecutionResult: .init(status: "Failed", endTimeUtc: now))]
        let rows = ServerDashboardLogic.healthRows(tasks: tasks, storage: nil, encoding: nil, sessions: [], now: now)
        XCTAssertEqual(rows.map(\.tone), [.failure])
        XCTAssertEqual(rows.first?.value, "Failed · now")
    }

    func testHardwareTranscodingRow() {
        let converting = session(transcoding: transcoding(video: false, audio: true))
        let on = ServerDashboardLogic.healthRows(
            tasks: [], storage: nil, encoding: EncodingOptionsSummary(hardwareAccelerationType: "qsv"), sessions: [converting], now: Date()
        )
        XCTAssertEqual(on.map(\.title), ["Hardware transcoding (QSV)"])
        XCTAssertEqual(on.first?.value, "On · 1 converting")
        let off = ServerDashboardLogic.healthRows(
            tasks: [], storage: nil, encoding: EncodingOptionsSummary(hardwareAccelerationType: "none"), sessions: [], now: Date()
        )
        XCTAssertEqual(off.first?.title, "Hardware transcoding")
        XCTAssertEqual(off.first?.value, "Off")
        XCTAssertEqual(off.first?.tone, .neutral, "no GPU is a choice, not a fault")
    }

    func testAttentionKeepsOnlyFailuresAndWarnings() {
        let health = [
            DashboardHealthRow(title: "Library scan", value: "OK", tone: .ok),
            DashboardHealthRow(title: "Cache drive", value: "90% full", tone: .warning)
        ]
        let activity = [
            DashboardActivityRow(id: 1, text: "mom is playing 300", when: "12 min", tone: .playback),
            DashboardActivityRow(id: 2, text: "Failed login attempt from admin", when: "2 h", tone: .failure)
        ]
        let attention = ServerDashboardLogic.attention(activity: activity, health: health)
        XCTAssertEqual(attention.map(\.text), ["Failed login attempt from admin", "Cache drive 90% full"])
    }

    // MARK: - Gate

    func testOnlyAnAdministratorTheServerHasNotRefusedSeesTheDashboard() {
        XCTAssertTrue(ServerDashboardLogic.canShowDashboard(isAdministrator: true, deniedByServer: false))
        XCTAssertFalse(ServerDashboardLogic.canShowDashboard(isAdministrator: true, deniedByServer: true))
        XCTAssertFalse(ServerDashboardLogic.canShowDashboard(isAdministrator: false, deniedByServer: false))
        XCTAssertFalse(ServerDashboardLogic.canShowDashboard(isAdministrator: false, deniedByServer: true))
    }

    func testForbiddenAndExpiredAreDenialsButServerErrorsAreNot() {
        XCTAssertTrue(ServerDashboardLogic.isAccessDenied(JellyfinError.httpError(statusCode: 403)))
        XCTAssertTrue(ServerDashboardLogic.isAccessDenied(JellyfinError.sessionExpired))
        XCTAssertFalse(ServerDashboardLogic.isAccessDenied(JellyfinError.httpError(statusCode: 500)))
        XCTAssertFalse(ServerDashboardLogic.isAccessDenied(URLError(.timedOut)))
    }

    // MARK: - Decoding the live shapes

    func testDecodesALiveSessionShape() throws {
        let json = #"""
        [{"Id":"abc","UserName":"mondo","Client":"Sashimi","DeviceName":"Sashimi tvOS","SupportsRemoteControl":false,
          "RemoteEndPoint":"10.0.0.1",
          "PlayState":{"PositionTicks":93598004,"IsPaused":true,"PlayMethod":"Transcode"},
          "NowPlayingItem":{"Id":"i","Name":"Matryoshka","Type":"Episode","SeriesName":"The 100","SeriesId":"s",
            "ParentIndexNumber":6,"IndexNumber":10,"RunTimeTicks":25442240000,
            "MediaStreams":[{"Type":"Video","Codec":"h264","Width":1920,"VideoRangeType":"SDR","BitRate":9747755}]},
          "TranscodingInfo":{"AudioCodec":"eac3","VideoCodec":"h264","Container":"mp4","IsVideoDirect":true,"IsAudioDirect":true,
            "Bitrate":10515755,"Width":1920,"Height":1080,"HardwareAccelerationType":"qsv","TranscodeReasons":["ContainerNotSupported"]}}]
        """#
        let sessions = try JSONDecoder().decode([DashboardSession].self, from: Data(json.utf8))
        let first = try XCTUnwrap(sessions.first)
        XCTAssertEqual(first.nowPlayingItem?.displayTitle, "The 100 · S6:E10 · Matryoshka")
        XCTAssertEqual(first.playState?.isPaused, true)
        XCTAssertEqual(ServerDashboardLogic.playMode(first.transcodingInfo), .directPlay)
        XCTAssertEqual(ServerDashboardLogic.detailLine(for: first), "1080p · Remux")
    }

    func testDecodesActivityDatesWithFractionalSeconds() throws {
        let json = #"{"Items":[{"Id":7,"Name":"x","Type":"SessionStarted","Date":"2026-10-18T19:37:48.1234567Z","Severity":"Information"}]}"#
        let page = try JSONDecoder().decode(ActivityLogPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.items.first?.date.timeIntervalSince1970 ?? 0, 1_792_352_268, accuracy: 1)
    }
}
