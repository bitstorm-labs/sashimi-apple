import XCTest
@testable import Sashimi

/// The spec's shared vectors (2026-11-12-settings-sync-schema.md, V1–V11)
/// against the pure rules. The same table runs on Android and Roku.
final class SettingsSyncTests: XCTestCase {
    private typealias Entry = SettingsSync.LayoutEntry

    private func kind(_ name: String) throws -> SettingsSync.Kind {
        try XCTUnwrap(SettingsSync.key(name)).kind
    }

    private func decide(_ name: String, local: SettingsSync.Value, stamp: Int64?, remote: String?) throws -> SettingsSync.Decision {
        let kind = try kind(name)
        return SettingsSync.decide(kind: kind, localValue: local, localStamp: stamp, remote: SettingsSync.decode(remote, kind: kind))
    }

    // MARK: Vectors

    func testV1NewerRemoteIsAppliedWithItsOwnStamp() throws {
        let decision = try decide("autoSkipIntro", local: .bool(false), stamp: 100, remote: #"{"v":true,"t":200}"#)
        XCTAssertEqual(decision, .apply(.init(value: .bool(true), t: 200)))
    }

    func testV2NewerLocalIsWritten() throws {
        let decision = try decide("autoSkipIntro", local: .bool(false), stamp: 300, remote: #"{"v":true,"t":200}"#)
        XCTAssertEqual(decision, .write(t: 300))
        XCTAssertEqual(SettingsSync.encode(.init(value: .bool(false), t: 300)), #"{"t":300,"v":false}"#)
    }

    func testV3EqualTimesDoNothing() throws {
        XCTAssertEqual(try decide("autoSkipIntro", local: .bool(false), stamp: 200, remote: #"{"v":true,"t":200}"#), .none)
    }

    func testV4ResumeThresholdOutsideTheListIsIgnored() throws {
        XCTAssertEqual(try decide("resumeThresholdSeconds", local: .int(30), stamp: 0, remote: #"{"v":45,"t":500}"#), .none)
        XCTAssertEqual(try decide("resumeThresholdSeconds", local: .int(30), stamp: 0, remote: #"{"v":10,"t":500}"#),
                       .apply(.init(value: .int(10), t: 500)), "10 seconds is on the aligned list")
    }

    func testV5UnknownShuffleModeIsIgnored() throws {
        XCTAssertEqual(try decide("tvShuffleMode", local: .string("randomEpisode"), stamp: nil, remote: #"{"v":"shuffleAll","t":500}"#), .none)
    }

    func testV6EveryOtherCustomPrefsKeySurvivesAWrite() throws {
        let stored = Data(#"{"Id":"x","SortBy":"Name","Client":"sashimi","CustomPrefs":{"subscriptions":"[]","skipBackLength":"10000","futureKey":"{\"v\":1,\"t\":9}"}}"#.utf8)
        let body = SettingsSync.displayPreferencesBody(stored: stored, writes: ["autoSkipIntro": #"{"t":5,"v":true}"#])
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["SortBy"] as? String, "Name")
        XCTAssertEqual(object["Id"] as? String, "x")
        let prefs = try XCTUnwrap(object["CustomPrefs"] as? [String: String])
        XCTAssertEqual(prefs["subscriptions"], "[]")
        XCTAssertEqual(prefs["skipBackLength"], "10000")
        XCTAssertEqual(prefs["futureKey"], #"{"v":1,"t":9}"#)
        XCTAssertEqual(prefs["autoSkipIntro"], #"{"t":5,"v":true}"#)
        XCTAssertEqual(prefs["schema"], "1")
    }

    func testV8IPhoneWriteKeepsTheHeroWhereTVOSPutIt() {
        let remote = [Entry(id: "continueWatching", on: true), Entry(id: "hero", on: true), Entry(id: "library:a", on: true)]
        let iPhone = [Entry(id: "continueWatching", on: true), Entry(id: "library:a", on: false)]
        let written = SettingsSync.writeLayout(local: iPhone, remote: remote)
        XCTAssertEqual(written.map(\.id), ["continueWatching", "hero", "library:a"])
        XCTAssertEqual(written[2].on, false, "the iPhone's own rows are written as it has them")
    }

    func testV9ALibraryTheRemoteLacksStaysAfterItsLocalPredecessor() {
        let local = [Entry(id: "continueWatching", on: true), Entry(id: "library:a", on: true),
                     Entry(id: "library:new", on: true), Entry(id: "library:b", on: true)]
        let remote = [Entry(id: "library:b", on: false), Entry(id: "continueWatching", on: true), Entry(id: "library:a", on: true)]
        let applied = SettingsSync.applyLayout(local: local, remote: remote)
        XCTAssertEqual(applied.map(\.id), ["library:b", "continueWatching", "library:a", "library:new"])
        XCTAssertEqual(applied.first?.on, false)
    }

    func testV10SeededSettingIsWrittenWithStampOneAndADefaultIsNot() throws {
        XCTAssertEqual(try decide("autoSkipIntro", local: .bool(true), stamp: SettingsSync.seedStamp, remote: nil), .write(t: 1))
        XCTAssertEqual(try decide("showQualityBadges", local: .bool(true), stamp: nil, remote: nil), .none)
    }

    func testV11MalformedRemoteIsIgnored() throws {
        XCTAssertEqual(SettingsSync.decode("{not json", kind: .bool), .unreadable)
        XCTAssertEqual(try decide("autoSkipIntro", local: .bool(false), stamp: 100, remote: "{not json"), .none)
    }

    // MARK: Codec

    func testEveryKindRoundTrips() throws {
        let cases: [(String, SettingsSync.Value)] = [
            ("autoPlayNextEpisode", .bool(false)),
            ("resumeThresholdSeconds", .int(600)),
            ("preferredAudioLanguage", .string("")),
            ("preferredSubtitleLanguage", .string("fi")),
            ("defaultViewMode", .string("stretch")),
            ("homeRows", .layout([Entry(id: "hero", on: true), Entry(id: "list:9d1c", on: false)])),
        ]
        for (name, value) in cases {
            let stamped = SettingsSync.Stamped(value: value, t: 1_762_963_200_000)
            XCTAssertEqual(SettingsSync.decode(SettingsSync.encode(stamped), kind: try kind(name)), .valid(stamped), name)
        }
    }

    func testTypesMustMatchExactly() {
        XCTAssertEqual(SettingsSync.decode(#"{"v":1,"t":5}"#, kind: .bool), .invalid(t: 5), "1 is not a bool")
        XCTAssertEqual(SettingsSync.decode(#"{"v":"true","t":5}"#, kind: .bool), .invalid(t: 5), "Roku converts to real bools")
        XCTAssertEqual(SettingsSync.decode(#"{"v":true,"t":5}"#, kind: .int(allowed: [1])), .invalid(t: 5))
        XCTAssertEqual(SettingsSync.decode(#"{"v":true}"#, kind: .bool), .unreadable, "no t")
        XCTAssertEqual(SettingsSync.decode(#"{"v":[{"id":"hero"}],"t":5}"#, kind: .layout), .invalid(t: 5))
    }

    func testANewerLocalChangeReplacesAnUnknownValueButAnOlderOneDoesNot() throws {
        XCTAssertEqual(try decide("tvShuffleMode", local: .string("randomEpisode"), stamp: 600, remote: #"{"v":"shuffleAll","t":500}"#), .write(t: 600))
        XCTAssertEqual(try decide("tvShuffleMode", local: .string("randomEpisode"), stamp: 400, remote: #"{"v":"shuffleAll","t":500}"#), .none)
    }

    func testCustomPrefsReadsOnlyStrings() {
        let data = Data(#"{"CustomPrefs":{"a":"x","b":null}}"#.utf8)
        XCTAssertEqual(SettingsSync.customPrefs(in: data), ["a": "x"])
        XCTAssertEqual(SettingsSync.customPrefs(in: nil), [:])
    }

    // MARK: Layout edits

    func testRowsComingAndGoingAreNotAnEdit() {
        let old = [Entry(id: "continueWatching", on: true), Entry(id: "library:a", on: true)]
        XCTAssertFalse(SettingsSync.isLayoutEdit(from: old, to: old + [Entry(id: "library:b", on: true)]))
        XCTAssertFalse(SettingsSync.isLayoutEdit(from: old, to: [old[0]]))
        XCTAssertTrue(SettingsSync.isLayoutEdit(from: old, to: old.reversed()))
        XCTAssertTrue(SettingsSync.isLayoutEdit(from: old, to: [old[0], Entry(id: "library:a", on: false)]))
    }

    // MARK: Row id mapping

    func testTVOSRowIdsMapBothWays() {
        let pairs = [("hero", "hero"), ("continueWatching", "continueWatching"), ("channels", "fintv"),
                     ("requests", "requests"), ("library_f137", "library:f137"), ("list_9d1c", "list:9d1c")]
        for (local, shared) in pairs {
            XCTAssertEqual(SettingsSync.RowIds.shared(tvOS: local), shared)
            XCTAssertEqual(SettingsSync.RowIds.tvOS(shared: shared), local)
        }
    }

    func testMobileRowIdsMapBothWays() {
        let pairs = [("continue_watching", "continueWatching"), ("channels", "fintv"), ("requests", "requests"),
                     ("f137", "library:f137"), ("list_9d1c", "list:9d1c")]
        for (local, shared) in pairs {
            XCTAssertEqual(SettingsSync.RowIds.shared(mobile: local), shared)
            XCTAssertEqual(SettingsSync.RowIds.mobile(shared: shared), local)
        }
        XCTAssertNil(SettingsSync.RowIds.mobile(shared: "hero"))
        XCTAssertNil(SettingsSync.RowIds.mobile(shared: "somethingNew"))
    }

    // MARK: tvOS rows

    @MainActor
    func testTVOSRowsTakeTheLayoutsOrderAndVisibility() {
        let rows: [HomeRowConfig] = [.builtIn(.hero), .builtIn(.continueWatching), .builtIn(.channels),
                                     .library(id: "a", name: "Movies"), .list(id: "L", title: "From Marge: Picks")]
        let layout = [Entry(id: "library:a", on: false), Entry(id: "hero", on: true), Entry(id: "unknown", on: true),
                      Entry(id: "list:L", on: true), Entry(id: "fintv", on: false), Entry(id: "continueWatching", on: true)]
        let applied = HomeRowsSettingsSync.rows(rows, applying: layout)
        XCTAssertEqual(applied.map(\.id), ["library_a", "hero", "list_L", "channels", "continueWatching"])
        XCTAssertEqual(applied.map(\.isVisible), [false, true, true, false, true])
        XCTAssertEqual(applied.first?.libraryName, "Movies", "the row itself is kept, only moved and switched")
        XCTAssertEqual(HomeRowsSettingsSync.layout(applied), [layout[0], layout[1], layout[3], layout[4], layout[5]])
    }
}
