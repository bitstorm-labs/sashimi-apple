import XCTest
@testable import Sashimi

final class ThemeSongPlayerTests: XCTestCase {
    func testAudioStreamURLShape() async throws {
        let client = JellyfinClient.shared
        let serverURL = try XCTUnwrap(URL(string: "http://example.test:8096"))
        await client.configure(serverURL: serverURL, accessToken: "TOKEN", userId: "USER")
        let audioURL = await client.getAudioStreamURL(itemId: "ITEM")
        let url = try XCTUnwrap(audioURL)
        // stream.mp3, not /universal - universal returns 400 without a profile.
        XCTAssertTrue(url.absoluteString.contains("/Audio/ITEM/stream.mp3"), url.absoluteString)
        XCTAssertTrue(url.absoluteString.contains("api_key=TOKEN"), url.absoluteString)
    }

    func testAudioStreamURLIsNilWhenUnconfigured() async {
        let client = JellyfinClient.shared
        await client.clearCredentials()
        let url = await client.getAudioStreamURL(itemId: "ITEM")
        XCTAssertNil(url)
    }
}
