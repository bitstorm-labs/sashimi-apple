import XCTest
@testable import Sashimi

/// The shared list rules. V1–V6 are the vectors every Sashimi client runs
/// (shared lists plan, Milestone 1); the rest are Apple's own.
final class SharedListsTests: XCTestCase {
    private func ep(_ id: String, _ series: String?, _ season: Int, _ episode: Int) -> ListEntry {
        ListEntry(itemId: id, type: .episode, seriesId: series, season: season, episode: episode)
    }
    private func mv(_ id: String) -> ListEntry {
        ListEntry(itemId: id, type: .movie, seriesId: nil, season: nil, episode: nil)
    }
    private func sub(_ id: String, _ seen: [String]) -> ListSubscription { ListSubscription(id: id, seen: seen) }

    // V1
    func testOwnerIsFirstEditableShare() {
        XCTAssertEqual(SharedLists.owner(shares: [
            PlaylistShare(userId: "u1", canEdit: false),
            PlaylistShare(userId: "u2", canEdit: true),
            PlaylistShare(userId: "u3", canEdit: true),
        ]), "u2")
        XCTAssertNil(SharedLists.owner(shares: []))
        XCTAssertNil(SharedLists.owner(shares: [PlaylistShare(userId: "u1", canEdit: false)]))
    }

    // V2
    func testPilotShowsAsSeriesAndDuplicatesCollapse() {
        let shown = SharedLists.displayEntries([
            ep("e1", "show1", 1, 1), mv("m1"), ep("e2", "show1", 1, 2), mv("m1"),
            ep("e3", "show2", 2, 1), ep("e4", nil, 1, 1), ep("e5", "show1", 1, 1),
        ])
        XCTAssertEqual(shown, [
            DisplayEntry(id: "show1", isSeries: true), DisplayEntry(id: "m1", isSeries: false),
            DisplayEntry(id: "e2", isSeries: false), DisplayEntry(id: "e3", isSeries: false),
            DisplayEntry(id: "e4", isSeries: false),
        ])
    }

    // V3
    func testDecodeToleratesMissingAndCorruptValues() {
        for raw in [nil, "", "not json", "{}"] {
            XCTAssertEqual(SharedLists.decodeSubscriptions(raw), [], "\(String(describing: raw))")
        }
        let raw = #"[{"id":"a","seen":["x"]},{"seen":[]},{"id":"a","seen":[]},{"id":"b"}]"#
        XCTAssertEqual(SharedLists.decodeSubscriptions(raw), [sub("a", ["x"]), sub("b", [])])
    }

    func testEncodeRoundTrips() {
        let subs = [sub("a", ["x", "y"]), sub("b", [])]
        XCTAssertEqual(SharedLists.decodeSubscriptions(SharedLists.encodeSubscriptions(subs)), subs)
    }

    /// The stored value is read by Android and Roku too, so its field names
    /// are part of the contract.
    func testEncodedFieldsAreIdAndSeen() throws {
        let raw = SharedLists.encodeSubscriptions([sub("a", ["x"])])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [[String: Any]])
        XCTAssertEqual(object.first?["id"] as? String, "a")
        XCTAssertEqual(object.first?["seen"] as? [String], ["x"])
    }

    // V4
    func testNewCountIgnoresSeenAndUnknownIds() {
        XCTAssertEqual(SharedLists.newCount(displayIds: ["a", "b", "c"], seen: ["b"]), 2)
        XCTAssertEqual(SharedLists.newCount(displayIds: ["a"], seen: ["a", "z"]), 0)
    }

    // V5
    func testSubscriptionEdits() {
        XCTAssertEqual(SharedLists.subscribe([sub("a", [])], id: "b", current: ["x", "y"]),
                       [sub("a", []), sub("b", ["x", "y"])])
        XCTAssertEqual(SharedLists.subscribe([sub("a", ["q"])], id: "a", current: ["x"]), [sub("a", ["q"])])
        XCTAssertEqual(SharedLists.unsubscribe([sub("a", []), sub("b", [])], id: "a"), [sub("b", [])])
        XCTAssertEqual(SharedLists.markSeen([sub("a", ["q"]), sub("b", [])], id: "a", current: ["x"]),
                       [sub("a", ["x"]), sub("b", [])])
        XCTAssertEqual(SharedLists.prune([sub("a", []), sub("b", []), sub("c", [])], missing: ["a", "c"]),
                       [sub("b", [])])
    }

    // V6
    func testNewRowGoesAfterContinueWatching() {
        let index = { (keys: [String]) in
            SharedLists.insertionIndex(rowKeys: keys, continueWatchingKey: "continueWatching", heroKey: "hero")
        }
        XCTAssertEqual(index(["hero", "continueWatching", "lib1"]), 2)
        XCTAssertEqual(index(["lib1", "hero"]), 2)
        XCTAssertEqual(index(["lib1"]), 0)
    }

    // MARK: - Apple only

    /// A show goes on a list as its first regular episode: specials (season 0)
    /// and episodes without numbers never anchor it.
    func testSeriesAnchorIsTheLowestRegularEpisode() {
        func episode(_ id: String, _ season: Int?, _ number: Int?) -> BaseItemDto {
            BaseItemDto.listFixture(id: id, type: .episode, seriesId: "show", season: season, episode: number)
        }
        let anchor = SharedLists.seriesAnchor([
            episode("special", 0, 1), episode("s2e1", 2, 1), episode("s1e3", 1, 3),
            episode("unnumbered", 1, nil), episode("s1e2", 1, 2),
        ])
        XCTAssertEqual(anchor?.id, "s1e2")
        XCTAssertNil(SharedLists.seriesAnchor([episode("special", 0, 1)]))
    }

    /// The save keeps every other key in the same DisplayPreferences entry: a
    /// future client may keep more there, and the server stores what it gets.
    func testDisplayPreferencesBodyKeepsOtherKeys() throws {
        let stored = #"{"Id":"x","Client":"sashimi","SortBy":"SortName","CustomPrefs":{"other":"keep","tvhome":null,"subscriptions":"[]"}}"#
        let body = SharedLists.displayPreferencesBody(stored: Data(stored.utf8), subscriptions: [sub("a", ["x"])])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let prefs = try XCTUnwrap(object["CustomPrefs"] as? [String: Any])
        XCTAssertEqual(object["SortBy"] as? String, "SortName")
        XCTAssertEqual(prefs["other"] as? String, "keep")
        XCTAssertTrue(prefs.keys.contains("tvhome"))
        XCTAssertEqual(SharedLists.decodeSubscriptions(prefs["subscriptions"] as? String), [sub("a", ["x"])])
    }

    func testDisplayPreferencesBodyFromNothingStillCarriesTheSubscriptions() throws {
        let body = SharedLists.displayPreferencesBody(stored: nil, subscriptions: [sub("a", [])])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["Client"] as? String, "sashimi")
        let prefs = try XCTUnwrap(object["CustomPrefs"] as? [String: Any])
        XCTAssertEqual(SharedLists.decodeSubscriptions(prefs["subscriptions"] as? String), [sub("a", [])])
    }

    /// "Already on this list" compares what the list shows, so a show is on a
    /// list when its S1:E1 is, and a movie when its own id is.
    func testAlreadyOnListComparesDisplayedTitles() {
        let entries = [ep("e1", "show1", 1, 1), mv("m1")]
        XCTAssertTrue(SharedLists.contains(entries, candidate: ep("e1-again", "show1", 1, 1)))
        XCTAssertTrue(SharedLists.contains(entries, candidate: mv("m1")))
        XCTAssertFalse(SharedLists.contains(entries, candidate: ep("e2", "show1", 1, 2)))
        XCTAssertFalse(SharedLists.contains(entries, candidate: mv("m2")))
    }

    func testRowTitleNamesTheCreator() {
        XCTAssertEqual(SharedLists.rowTitle(listName: "Christmas Movies", ownerName: "Marge"), "From Marge: Christmas Movies")
        XCTAssertEqual(SharedLists.rowTitle(listName: "Picks", ownerName: nil), "Picks")
    }
}

extension BaseItemDto {
    /// A minimal item for list tests.
    static func listFixture(
        id: String,
        type: ItemType,
        seriesId: String? = nil,
        season: Int? = nil,
        episode: Int? = nil
    ) -> BaseItemDto {
        let json: [String: Any?] = [
            "Id": id, "Name": id, "Type": type.rawValue, "SeriesId": seriesId,
            "ParentIndexNumber": season, "IndexNumber": episode,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: json.compactMapValues { $0 })) ?? Data()
        // swiftlint:disable:next force_try
        return try! JSONDecoder().decode(BaseItemDto.self, from: data)
    }
}

/// Home rows follow the subscriptions without disturbing the user's order.
final class SharedListRowSyncTests: XCTestCase {
    private func sync(_ current: [String], _ lists: [String]) -> [String] {
        SharedLists.syncedRowKeys(
            current: current,
            listKeys: lists,
            isListKey: { $0.hasPrefix("list_") },
            continueWatchingKey: "continueWatching",
            heroKey: "hero"
        )
    }

    func testNewSubscriptionsGoAfterContinueWatchingInOrder() {
        XCTAssertEqual(sync(["hero", "continueWatching", "lib1"], ["list_a", "list_b"]),
                       ["hero", "continueWatching", "list_a", "list_b", "lib1"])
    }

    func testAMovedRowStaysWhereTheUserPutIt() {
        XCTAssertEqual(sync(["hero", "continueWatching", "lib1", "list_a"], ["list_a", "list_b"]),
                       ["hero", "continueWatching", "list_b", "lib1", "list_a"])
    }

    func testAnUnsubscribedListLosesItsRow() {
        XCTAssertEqual(sync(["continueWatching", "list_a", "lib1", "list_b"], ["list_b"]),
                       ["continueWatching", "lib1", "list_b"])
    }
}
