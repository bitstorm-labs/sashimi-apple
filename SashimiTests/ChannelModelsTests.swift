import XCTest
@testable import Sashimi

/// Decoding a channel's current programme.
///
/// The dates are the whole point here: they drive both the countdown and the
/// join-position bar, so a date that fails to parse does not look like an error
/// — it looks like the feature being subtly wrong.
final class ChannelModelsTests: XCTestCase {
    /// Verbatim from the server, including .NET's seven fractional digits.
    private let payload = """
    {
      "ItemId": "47df27cb7936d76160695d3cdf3e505f",
      "StartPositionSeconds": 821.8519418,
      "StartUtc": "2026-09-18T20:26:19.9749994Z",
      "EndUtc": "2026-09-18T20:47:47.5249994Z",
      "NextItemId": "ea3f596e84c4b365114437f0c4cc9dcb"
    }
    """.utf8Data

    func testDecodesDatesWithFractionalSeconds() throws {
        // JSONDecoder's .iso8601 strategy rejects fractional seconds outright,
        // which is what broke the countdown and the progress bar.
        let now = try JSONDecoder().decode(ChannelNowPlaying.self, from: payload)

        XCTAssertEqual(now.itemId, "47df27cb7936d76160695d3cdf3e505f")
        XCTAssertEqual(now.startPositionSeconds, 821.8519418, accuracy: 0.001)
        XCTAssertEqual(now.nextItemId, "ea3f596e84c4b365114437f0c4cc9dcb")

        // 20:26:19.975 -> 20:47:47.525 is 1287.55s of programme.
        XCTAssertEqual(now.endUtc.timeIntervalSince(now.startUtc), 1287.55, accuracy: 0.1)
    }

    func testDecodesDatesWithoutFractionalSeconds() throws {
        // The server omits them when a value lands on a whole second, so both
        // shapes arrive in practice — parsing only one is why the countdown
        // worked intermittently rather than never.
        let whole = """
        {"ItemId":"a","StartPositionSeconds":0,
         "StartUtc":"2026-09-18T20:00:00Z","EndUtc":"2026-09-18T20:30:00Z","NextItemId":null}
        """.utf8Data

        let now = try JSONDecoder().decode(ChannelNowPlaying.self, from: whole)

        XCTAssertEqual(now.endUtc.timeIntervalSince(now.startUtc), 1800, accuracy: 0.1)
        XCTAssertNil(now.nextItemId)
    }

    func testProgressReflectsHowFarIntoTheProgrammeAViewerJoins() throws {
        let now = try JSONDecoder().decode(ChannelNowPlaying.self, from: payload)
        let card = ChannelCard(
            channel: VirtualChannel(id: "c", name: "Test", timeZoneId: "UTC", daypartCount: 1),
            nowPlaying: now,
            item: nil
        )

        // 821.85s into a 1287.55s programme is ~64%. With unparseable dates the
        // denominator collapses and this reads 0 or 1 — a bar that is always
        // empty or always full, which is how the bug actually presented.
        XCTAssertEqual(card.progress, 0.638, accuracy: 0.01)
    }

    func testAnUnparseableDateFailsLoudlyRatherThanSilently() {
        let bad = """
        {"ItemId":"a","StartPositionSeconds":0,
         "StartUtc":"not a date","EndUtc":"2026-09-18T20:30:00Z","NextItemId":null}
        """.utf8Data

        XCTAssertThrowsError(try JSONDecoder().decode(ChannelNowPlaying.self, from: bad))
    }
}

private extension String {
    /// `Data(_:)` over `data(using:)!` — the linter rejects the force unwrap,
    /// and a UTF-8 conversion cannot fail anyway.
    var utf8Data: Data { Data(utf8) }
}
