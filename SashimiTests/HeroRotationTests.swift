import XCTest
@testable import Sashimi

/// Channel slides are spread through the hero rotation, not grouped.
final class HeroRotationTests: XCTestCase {
    private func item(_ id: String, type: ItemType = .movie) -> BaseItemDto {
        BaseItemDto(
            id: id, name: id, type: type,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil, productionYear: nil,
            communityRating: nil, officialRating: nil, genres: nil,
            taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
    }

    private func libraryItem(_ id: String) -> HeroSlide {
        .library(item(id))
    }

    private func channelSlide(_ id: String) -> HeroSlide {
        HeroSlide(
            item: item("item-\(id)", type: .episode),
            channel: HeroSlide.Stamp(id: id, name: id, endsAt: nil)
        )
    }

    private func ids(_ slides: [HeroSlide]) -> [String] {
        slides.map(\.id)
    }

    // MARK: - Spreading

    func testChannelsAreSpreadNotGrouped() {
        let base = (1...6).map { libraryItem("l\($0)") }
        let result = HeroRotation.interleave(base: base, inserts: [channelSlide("a"), channelSlide("b")])

        XCTAssertEqual(
            ids(result),
            ["item:l1", "item:l2", "item:l3", "channel:a",
             "item:l4", "item:l5", "item:l6", "channel:b"],
            "One channel every three library slides, not both at one end"
        )
    }

    func testNoTwoChannelsAreAdjacentWhenThereIsRoom() {
        let base = (1...12).map { libraryItem("l\($0)") }
        let result = HeroRotation.interleave(base: base, inserts: (1...4).map { channelSlide("c\($0)") })

        let channelPositions = result.enumerated()
            .filter { $0.element.channel != nil }
            .map(\.offset)
        let gaps = zip(channelPositions, channelPositions.dropFirst()).map { $1 - $0 }

        XCTAssertEqual(result.count, 16)
        XCTAssertTrue(gaps.allSatisfy { $0 > 1 }, "Channels ended up adjacent: \(channelPositions)")
    }

    // MARK: - Nothing is lost

    func testEveryChannelSurvivesEvenWithFewerLibraryItems() {
        let base = [libraryItem("l1")]
        let inserts = (1...4).map { channelSlide("c\($0)") }
        let result = HeroRotation.interleave(base: base, inserts: inserts)

        XCTAssertEqual(result.count, 5, "A short rotation must not drop channels")
        XCTAssertEqual(Set(ids(result)), Set(ids(base) + ids(inserts)))
    }

    func testOrderOfEachGroupIsPreserved() {
        let base = (1...4).map { libraryItem("l\($0)") }
        let inserts = (1...2).map { channelSlide("c\($0)") }
        let result = HeroRotation.interleave(base: base, inserts: inserts)

        XCTAssertEqual(ids(result).filter { $0.hasPrefix("item:") }, ids(base))
        XCTAssertEqual(ids(result).filter { $0.hasPrefix("channel:") }, ids(inserts))
    }

    // MARK: - Empty sides

    func testNoChannelsLeavesTheRotationUntouched() {
        let base = (1...3).map { libraryItem("l\($0)") }
        XCTAssertEqual(ids(HeroRotation.interleave(base: base, inserts: [])), ids(base))
    }

    func testChannelsAloneAreTheWholeRotation() {
        let inserts = (1...3).map { channelSlide("c\($0)") }
        XCTAssertEqual(ids(HeroRotation.interleave(base: [], inserts: inserts)), ids(inserts))
    }

    // MARK: - Identity

    func testTwoChannelsAiringTheSameItemStayDistinct() {
        let shared = item("shared", type: .episode)
        let a = HeroSlide(item: shared, channel: .init(id: "a", name: "A", endsAt: nil))
        let b = HeroSlide(item: shared, channel: .init(id: "b", name: "B", endsAt: nil))

        XCTAssertNotEqual(a.id, b.id, "Slide ids collide, so the rotation would drop one")
    }

    // MARK: - Countdown

    func testTimeRemainingMatchesTheCardWording() {
        let now = Date()
        let stamp = { (seconds: TimeInterval) in
            HeroSlide.Stamp(id: "c", name: "C", endsAt: now.addingTimeInterval(seconds))
        }

        XCTAssertEqual(stamp(4500).timeRemaining(at: now), "1h 15m left")
        XCTAssertEqual(stamp(780).timeRemaining(at: now), "13m left")
        XCTAssertEqual(stamp(30).timeRemaining(at: now), "30s left")
        XCTAssertEqual(stamp(-60).timeRemaining(at: now), "0s left", "A finished programme must not count backwards")
        XCTAssertNil(HeroSlide.Stamp(id: "c", name: "C", endsAt: nil).timeRemaining(at: now))
    }
}
