import XCTest
@testable import Sashimi

/// The store behind #774: what it keeps, for how long, and how many.
final class PlaybackTrackMemoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName = ""
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "PlaybackTrackMemoryTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func memory() -> PlaybackTrackMemory {
        PlaybackTrackMemory(defaults: defaults, now: { [unowned self] in clock })
    }

    private let sdh = PlaybackTrackMemory.Subtitle(language: "eng", displayTitle: "English SDH", isExternal: false)
    private let japanese = PlaybackTrackMemory.Audio(language: "jpn", displayName: "Japanese")

    func testRemembersBothPicksForTheItem() {
        memory().remember(itemID: "a", subtitle: sdh, audio: japanese)

        let entry = memory().recall(itemID: "a")
        XCTAssertEqual(entry?.subtitle, sdh)
        XCTAssertEqual(entry?.audio, japanese)
        XCTAssertNil(memory().recall(itemID: "b"))
    }

    func testNoPicksForgetsTheItem() {
        memory().remember(itemID: "a", subtitle: sdh, audio: nil)
        memory().remember(itemID: "a", subtitle: nil, audio: nil)

        XCTAssertNil(memory().recall(itemID: "a"))
    }

    func testPicksExpire() {
        memory().remember(itemID: "a", subtitle: sdh, audio: nil)

        clock += PlaybackTrackMemory.lifetime - 60
        XCTAssertNotNil(memory().recall(itemID: "a"))
        clock += 120
        XCTAssertNil(memory().recall(itemID: "a"))
    }

    func testKeepsOnlyTheMostRecentItems() {
        for number in 0...PlaybackTrackMemory.capacity {
            clock += 1
            memory().remember(itemID: "item-\(number)", subtitle: sdh, audio: nil)
        }

        XCTAssertNil(memory().recall(itemID: "item-0"), "the oldest item goes first")
        XCTAssertNotNil(memory().recall(itemID: "item-1"))
        XCTAssertNotNil(memory().recall(itemID: "item-\(PlaybackTrackMemory.capacity)"))
    }
}
