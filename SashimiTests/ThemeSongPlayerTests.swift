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

    // MARK: - ThemeMediaResponse decoding
    //
    // `getThemeSongs` swallows decode failures with `try?` and treats the
    // result as "no theme" - the same outcome as the ~41% of series that
    // legitimately have none. A CodingKeys typo or wrong nesting here would
    // compile, pass lint, and be invisible at runtime. These tests decode
    // `ThemeMediaResponse` directly (moved to file scope in
    // Shared/Models/JellyfinModels.swift for testability, same pattern as
    // `AuthenticationResult`/`PlaybackInfoResponse`) so they exercise the
    // real production type, not a hand-copied re-implementation of it.

    /// `Id`/`Name`/`Type` below are copied verbatim from a real
    /// `/Items/{id}/ThemeMedia` response captured against a live Jellyfin
    /// 10.11.11 server for a themed series (surrounding per-item fields
    /// such as MediaSources/MediaStreams are trimmed - BaseItemDto doesn't
    /// decode them and they don't affect this test).
    private static let populatedThemeMediaJSON = """
    {
      "ThemeVideosResult": { "Items": [], "TotalRecordCount": 0 },
      "ThemeSongsResult": {
        "Items": [
          {
            "Name": "theme",
            "Id": "502e1840465f20b46ae1bbc6412466ed",
            "Type": "Audio"
          }
        ],
        "TotalRecordCount": 1
      },
      "SoundtrackSongsResult": { "Items": [], "TotalRecordCount": 0 }
    }
    """

    /// Shape of the normal (no-theme) case: all three result sets present
    /// with empty `Items` - not an error, ~41% of a typical library.
    private static let emptyThemeMediaJSON = """
    {
      "ThemeVideosResult": { "Items": [], "TotalRecordCount": 0 },
      "ThemeSongsResult": { "Items": [], "TotalRecordCount": 0 },
      "SoundtrackSongsResult": { "Items": [], "TotalRecordCount": 0 }
    }
    """

    /// Synthetic (not captured) fixture: each of the three sibling result
    /// sets holds a distinctly-named/ID'd item, so decoding the wrong key
    /// is caught by an ID mismatch rather than an incidentally-empty array.
    private static let siblingDiscriminationJSON = """
    {
      "ThemeVideosResult": {
        "Items": [{ "Name": "decoy-video", "Id": "video-decoy-id", "Type": "Video" }],
        "TotalRecordCount": 1
      },
      "ThemeSongsResult": {
        "Items": [{ "Name": "theme", "Id": "real-theme-id", "Type": "Audio" }],
        "TotalRecordCount": 1
      },
      "SoundtrackSongsResult": {
        "Items": [{ "Name": "decoy-soundtrack", "Id": "soundtrack-decoy-id", "Type": "Audio" }],
        "TotalRecordCount": 1
      }
    }
    """

    func testThemeMediaResponseDecodesPopulatedThemeSongsResult() throws {
        let data = try XCTUnwrap(Self.populatedThemeMediaJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ThemeMediaResponse.self, from: data)
        let items = try XCTUnwrap(decoded.themeSongsResult?.items)
        XCTAssertEqual(items.count, 1)
        let theme = try XCTUnwrap(items.first)
        XCTAssertEqual(theme.id, "502e1840465f20b46ae1bbc6412466ed")
        XCTAssertEqual(theme.name, "theme")
        // Server sends Type "Audio", which ItemType has no case for; it must
        // fall back to .unknown (via ItemType's custom init) rather than
        // throwing - if that fallback is ever "tidied away", this item (and
        // every real theme song) stops decoding.
        XCTAssertEqual(theme.type, .unknown)
    }

    func testThemeMediaResponseDecodesEmptyResultToEmptyArray() throws {
        let data = try XCTUnwrap(Self.emptyThemeMediaJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ThemeMediaResponse.self, from: data)
        XCTAssertEqual(decoded.themeSongsResult?.items ?? [], [])
    }

    func testThemeMediaResponseReadsThemeSongsResultNotSiblings() throws {
        let data = try XCTUnwrap(Self.siblingDiscriminationJSON.data(using: .utf8))
        let decoded = try JSONDecoder().decode(ThemeMediaResponse.self, from: data)
        let items = try XCTUnwrap(decoded.themeSongsResult?.items)
        XCTAssertEqual(items.map(\.id), ["real-theme-id"])
        XCTAssertFalse(items.map(\.id).contains("video-decoy-id"))
        XCTAssertFalse(items.map(\.id).contains("soundtrack-decoy-id"))
    }
}

@MainActor
final class ThemeSongResolutionTests: XCTestCase {
    func testResolvesOncePerSeriesThenCaches() async {
        let player = ThemeSongPlayer(startDelay: 0)
        var calls: [String] = []
        player.resolver = { id in calls.append(id); return URL(string: "http://x/\(id).mp3") }

        _ = await player.resolveForTest("A")
        _ = await player.resolveForTest("A")
        XCTAssertEqual(calls, ["A"], "second lookup must come from cache")
    }

    func testCachesMissesToo() async {
        // ~40% of series have no theme. Re-entering one must not re-query.
        let player = ThemeSongPlayer(startDelay: 0)
        var calls = 0
        player.resolver = { _ in calls += 1; return nil }

        let first = await player.resolveForTest("A")
        let second = await player.resolveForTest("A")
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(calls, 1, "a miss must be cached, not retried")
    }

    func testDisabledSettingResolvesNothing() async {
        let player = ThemeSongPlayer(startDelay: 0)
        var calls = 0
        player.resolver = { _ in calls += 1; return nil }
        PlaybackSettings.shared.playThemeSongs = false
        defer { PlaybackSettings.shared.playThemeSongs = true }

        player.showAppeared(seriesId: "A")
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(calls, 0, "nothing is fetched when the setting is off")
    }

    /// A thrown error (network failure, request cancellation) is not the
    /// same fact as "this series has no theme" and must not be cached the
    /// same way `testCachesMissesToo` proves a clean `nil` is. Bouncing in
    /// and out of a detail screen inside the start delay cancels the
    /// in-flight request every time; if that got cached as a permanent miss,
    /// the series would never get its theme resolved again for the session.
    func testThrowingResolverIsNotCached() async {
        struct ResolveFailure: Error {}
        let player = ThemeSongPlayer(startDelay: 0)
        var calls = 0
        player.resolver = { _ in
            calls += 1
            throw ResolveFailure()
        }

        let first = await player.resolveForTest("A")
        let second = await player.resolveForTest("A")
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(calls, 2, "a thrown error must not be cached; every visit should retry")
    }
}
