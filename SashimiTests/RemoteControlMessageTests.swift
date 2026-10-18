import XCTest
@testable import Sashimi

/// The Jellyfin `/socket` protocol as the live 12.2 server speaks it (frames
/// below were captured from it), and the pure policies around it.
final class RemoteControlMessageTests: XCTestCase {
    private func parse(_ json: String) -> RemoteControlMessage {
        RemoteControlMessage.parse(json)
    }

    // MARK: - Parsing

    func testForceKeepAliveCarriesTheServersTimeout() {
        let frame = #"{"MessageId":"9c26","Data":60,"MessageType":"ForceKeepAlive"}"#
        XCTAssertEqual(parse(frame), .forceKeepAlive(seconds: 60))
    }

    func testKeepAliveEcho() {
        XCTAssertEqual(parse(#"{"MessageType":"KeepAlive"}"#), .keepAlive)
    }

    func testPlaystateStop() {
        let frame = #"{"MessageId":"b5e9","Data":{"Command":"Stop"},"MessageType":"Playstate"}"#
        XCTAssertEqual(parse(frame), .command(.stop))
    }

    func testOtherPlaystateCommandsAreIgnored() {
        for command in ["Pause", "Unpause", "PlayPause", "Seek", "NextTrack", "PreviousTrack", "Rewind", "FastForward"] {
            let frame = #"{"Data":{"Command":"\#(command)","SeekPositionTicks":100},"MessageType":"Playstate"}"#
            XCTAssertEqual(parse(frame), .ignored, command)
        }
    }

    func testDisplayMessageWithStringTimeoutAsTheServerSendsIt() {
        let frame = #"""
        {"MessageId":"7138","Data":{"Name":"DisplayMessage","ControllingUserId":"0000",
        "Arguments":{"Header":"Hi","Text":"probe text","TimeoutMs":"4000"}},"MessageType":"GeneralCommand"}
        """#
        XCTAssertEqual(parse(frame), .command(.displayMessage(RemoteMessage(header: "Hi", text: "probe text", timeoutMs: 4000))))
    }

    func testDisplayMessageWithNumericTimeout() {
        let frame = #"{"Data":{"Name":"DisplayMessage","Arguments":{"Header":"H","Text":"T","TimeoutMs":2500}},"MessageType":"GeneralCommand"}"#
        XCTAssertEqual(parse(frame), .command(.displayMessage(RemoteMessage(header: "H", text: "T", timeoutMs: 2500))))
    }

    func testDisplayMessageWithoutTimeoutOrHeader() {
        let frame = #"{"Data":{"Name":"DisplayMessage","Arguments":{"Text":"Dinner"}},"MessageType":"GeneralCommand"}"#
        XCTAssertEqual(parse(frame), .command(.displayMessage(RemoteMessage(header: nil, text: "Dinner", timeoutMs: nil))))
    }

    func testDisplayMessageWithAnUnreadableTimeoutKeepsTheMessage() {
        let frame = #"{"Data":{"Name":"DisplayMessage","Arguments":{"Text":"Dinner","TimeoutMs":"soon"}},"MessageType":"GeneralCommand"}"#
        XCTAssertEqual(parse(frame), .command(.displayMessage(RemoteMessage(header: nil, text: "Dinner", timeoutMs: nil))))
    }

    func testHeaderOnlyMessageShowsTheHeader() {
        let frame = #"{"Data":{"Name":"DisplayMessage","Arguments":{"Header":"Bedtime","Text":"  "}},"MessageType":"GeneralCommand"}"#
        XCTAssertEqual(parse(frame), .command(.displayMessage(RemoteMessage(header: "Bedtime", text: "", timeoutMs: nil))))
    }

    func testEmptyMessageIsIgnored() {
        let frame = #"{"Data":{"Name":"DisplayMessage","Arguments":{"Header":" ","Text":""}},"MessageType":"GeneralCommand"}"#
        XCTAssertEqual(parse(frame), .ignored)
        XCTAssertEqual(parse(#"{"Data":{"Name":"DisplayMessage"},"MessageType":"GeneralCommand"}"#), .ignored)
    }

    func testOtherGeneralCommandsAreIgnored() {
        for name in ["SetVolume", "Mute", "GoHome", "DisplayContent", "SendString", "ToggleFullscreen"] {
            let frame = #"{"Data":{"Name":"\#(name)","Arguments":{"Header":"H","Text":"T","Volume":"5"}},"MessageType":"GeneralCommand"}"#
            XCTAssertEqual(parse(frame), .ignored, name)
        }
    }

    func testOtherMessageTypesAndGarbageAreIgnored() {
        XCTAssertEqual(parse(#"{"MessageType":"Play","Data":{"ItemIds":["a"],"PlayCommand":"PlayNow"}}"#), .ignored)
        XCTAssertEqual(parse(#"{"MessageType":"UserDataChanged","Data":{}}"#), .ignored)
        XCTAssertEqual(parse(#"{"MessageType":"Playstate","Data":"Stop"}"#), .ignored)
        XCTAssertEqual(parse(#"{"Data":{"Command":"Stop"}}"#), .ignored)
        XCTAssertEqual(parse("not json"), .ignored)
        XCTAssertEqual(parse("[1,2]"), .ignored)
        XCTAssertEqual(parse(""), .ignored)
    }

    func testKeepAliveFrameIsWhatTheServerExpects() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(RemoteControlMessage.keepAliveFrame.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["MessageType"] as? String, "KeepAlive")
    }

    // MARK: - Keep-alive interval

    func testKeepAliveRunsAtHalfTheServersTimeout() {
        XCTAssertEqual(RemoteControlMessage.keepAliveInterval(forTimeout: 60), 30)
        XCTAssertEqual(RemoteControlMessage.keepAliveInterval(forTimeout: 20), 10)
    }

    func testKeepAliveIntervalHasAFloor() {
        XCTAssertEqual(RemoteControlMessage.keepAliveInterval(forTimeout: 0), 30, "no timeout: the default")
        XCTAssertEqual(RemoteControlMessage.keepAliveInterval(forTimeout: -4), 30)
        XCTAssertEqual(RemoteControlMessage.keepAliveInterval(forTimeout: 4), 5, "never hammer the server")
    }

    // MARK: - Reconnect backoff

    func testReconnectBackoffDoublesUpToTheCap() {
        let policy = RemoteControlReconnectPolicy(initialDelay: 1, maximumDelay: 30)
        XCTAssertEqual((0..<8).map(policy.delay(forAttempt:)), [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testReconnectBackoffSurvivesAbsurdAttemptCounts() {
        let policy = RemoteControlReconnectPolicy(initialDelay: 1, maximumDelay: 30)
        XCTAssertEqual(policy.delay(forAttempt: 10_000), 30)
        XCTAssertEqual(policy.delay(forAttempt: -1), 1)
    }

    func testDefaultBackoff() {
        let policy = RemoteControlReconnectPolicy()
        XCTAssertEqual(policy.delay(forAttempt: 0), 1)
        XCTAssertEqual(policy.delay(forAttempt: 20), 60)
    }

    // MARK: - Banner duration

    func testBannerHonoursTimeoutMs() {
        XCTAssertEqual(RemoteMessage(header: nil, text: "x", timeoutMs: 4000).displayDuration, 4)
        XCTAssertEqual(RemoteMessage(header: nil, text: "x", timeoutMs: 12_500).displayDuration, 12.5)
    }

    func testBannerDurationDefaultsAndClamps() {
        XCTAssertEqual(RemoteMessage(header: nil, text: "x", timeoutMs: nil).displayDuration, RemoteMessage.defaultDuration)
        XCTAssertEqual(RemoteMessage(header: nil, text: "x", timeoutMs: 0).displayDuration, RemoteMessage.defaultDuration)
        XCTAssertEqual(RemoteMessage(header: nil, text: "x", timeoutMs: 100).displayDuration, 2, "readable for at least 2s")
        XCTAssertEqual(RemoteMessage(header: nil, text: "x", timeoutMs: 3_600_000).displayDuration, 60, "never stuck on screen")
    }
}
