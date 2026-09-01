import XCTest
@testable import Sashimi

final class SashimiMediaEntityIdentifierTests: XCTestCase {
    func testRoundTripPreservesServerAndItemIDs() {
        let original = SashimiMediaEntityIdentifier(
            serverID: "server-1",
            itemID: "movie-42"
        )

        let parsed = SashimiMediaEntityIdentifier(rawValue: original.rawValue)

        XCTAssertEqual(parsed, original)
    }

    func testSameJellyfinIDOnDifferentServersIsDifferent() {
        let first = SashimiMediaEntityIdentifier(serverID: "server-a", itemID: "same-item")
        let second = SashimiMediaEntityIdentifier(serverID: "server-b", itemID: "same-item")

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first.rawValue, second.rawValue)
    }

    func testPunctuationInEitherComponentDoesNotBreakParsing() {
        let original = SashimiMediaEntityIdentifier(
            serverID: "https://jellyfin.example:8096",
            itemID: "item:with/punctuation"
        )

        XCTAssertEqual(SashimiMediaEntityIdentifier(rawValue: original.rawValue), original)
    }

    func testMalformedValuesAreRejected() {
        XCTAssertNil(SashimiMediaEntityIdentifier(rawValue: "missing-length"))
        XCTAssertNil(SashimiMediaEntityIdentifier(rawValue: "0:item"))
        XCTAssertNil(SashimiMediaEntityIdentifier(rawValue: "4:serv"))
        XCTAssertNil(SashimiMediaEntityIdentifier(rawValue: "6:server"))
    }
}
