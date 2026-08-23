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
        let player = ThemeSongPlayer(timings: ThemeSongTimings(startDelay: 0))
        var calls: [String] = []
        player.resolver = { id in calls.append(id); return "theme-\(id)" }
        player.urlBuilder = { themeId in URL(string: "http://x/\(themeId).mp3") }

        _ = await player.resolveForTest("A")
        _ = await player.resolveForTest("A")
        XCTAssertEqual(calls, ["A"], "second lookup must come from cache")
    }

    /// `getAudioStreamURL` bakes the *current* access token into the URL it
    /// returns. If that URL were cached alongside the theme item id, an
    /// in-session re-login would leave every previously-visited series
    /// carrying a stale token — permanently silent for the rest of the
    /// session. Caching only the id (never the URL) is what this test pins:
    /// the id lookup happens once, but the URL reflects whatever credential
    /// is current at the moment of each individual resolve.
    func testCachedThemeIdSurvivesCredentialChangeAndBuildsAFreshURL() async {
        let player = ThemeSongPlayer(timings: ThemeSongTimings(startDelay: 0))
        var resolverCalls = 0
        player.resolver = { _ in resolverCalls += 1; return "theme-item-id" }

        var currentToken = "TOKEN-1"
        player.urlBuilder = { themeId in URL(string: "http://x/\(themeId).mp3?api_key=\(currentToken)") }

        let first = await player.resolveForTest("A")
        currentToken = "TOKEN-2" // simulate an in-session re-login rotating the access token
        let second = await player.resolveForTest("A")

        XCTAssertEqual(resolverCalls, 1, "the theme item id is cached - no second lookup for the same series")
        XCTAssertEqual(first?.absoluteString, "http://x/theme-item-id.mp3?api_key=TOKEN-1")
        XCTAssertEqual(
            second?.absoluteString, "http://x/theme-item-id.mp3?api_key=TOKEN-2",
            "the URL must be rebuilt fresh on every resolve, not cached alongside the id"
        )
    }

    func testCachesMissesToo() async {
        // ~40% of series have no theme. Re-entering one must not re-query.
        let player = ThemeSongPlayer(timings: ThemeSongTimings(startDelay: 0))
        var calls = 0
        player.resolver = { _ in calls += 1; return nil }

        let first = await player.resolveForTest("A")
        let second = await player.resolveForTest("A")
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(calls, 1, "a miss must be cached, not retried")
    }

    func testDisabledSettingResolvesNothing() async {
        let player = ThemeSongPlayer(timings: ThemeSongTimings(startDelay: 0))
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
        let player = ThemeSongPlayer(timings: ThemeSongTimings(startDelay: 0))
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

    /// Backgrounding does not dismiss the detail screens on top of it - they
    /// stay mounted, so returning to the same show (e.g. opening a season
    /// after backgrounding from its Series screen) must still read as the
    /// *same* visit, not a fresh one. `appDidBackground()` resetting the
    /// visit state would make the very next `showAppeared` for that series
    /// look new and replay the theme a second time.
    func testBackgroundingDoesNotReplayTheThemeForTheSameVisit() async {
        let player = ThemeSongPlayer(timings: ThemeSongTimings(startDelay: 0))
        player.resolver = { _ in "theme-item-id" }
        // Counting `urlBuilder` calls, not `resolver` calls: the theme item
        // id is cached per series, so a naive resolver-call count would stay
        // 1 either way and silently fail to catch the regression - the id
        // cache would mask it. `urlBuilder` runs once per *attempt* to start
        // a theme (it is deliberately never cached, per fix 3 above), so its
        // call count is what actually reflects whether `showAppeared`
        // treated the second call as a new visit.
        var urlBuilderCalls = 0
        player.urlBuilder = { _ in urlBuilderCalls += 1; return nil }

        player.showAppeared(seriesId: "A")
        try? await Task.sleep(nanoseconds: 20_000_000)

        player.appDidBackground()

        // The season screen appears next, for the same series - still the
        // same visit.
        player.showAppeared(seriesId: "A")
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertEqual(urlBuilderCalls, 1, "returning to the same visit after backgrounding must not re-trigger a theme start")
    }
}

/// The theme is allowed to override the iOS Ring/Silent switch (it sets
/// `.playback` before starting, issue #393), which means it also claims audio
/// focus. That is only acceptable because it never does so while another app
/// owns the audio: a podcast or album the user deliberately started must not
/// be stopped by walking onto a detail screen.
///
/// `isOtherAudioPlaying` is the injectable seam that decision hangs off,
/// because the real signal (`AVAudioSession.isOtherAudioPlaying`) cannot be
/// produced on a simulator — and this suite is tvOS-hosted, where the
/// production default is a constant `false` by design.
///
/// Red-verified: inverting the guard in `scheduleStart` to
/// `guard isOtherAudioPlaying()` makes
/// `testOtherAudioPlayingSkipsTheThemeEntirely` and
/// `testNoOtherAudioLetsTheThemeStart` fail, and deleting the guard outright
/// makes `testOtherAudioPlayingSkipsTheThemeEntirely` fail. Neither passes
/// against code without the fix.
@MainActor
final class ThemeSongOtherAudioGateTests: XCTestCase {
    /// A reserved, non-routable address: `AVPlayerItem`/`AVPlayer`
    /// construction and `play()` are local operations, so nothing here needs
    /// the stream to resolve.
    private func themeURL() throws -> URL {
        try XCTUnwrap(URL(string: "http://192.0.2.1:1/theme.mp3"))
    }

    /// The whole point of the gate: not "start quietly", not "start and duck"
    /// — nothing happens at all. No session change (there is none to observe
    /// here, hence the player assertion), and crucially no network request,
    /// which is why the resolver/urlBuilder counts must both stay at zero.
    func testOtherAudioPlayingSkipsTheThemeEntirely() async throws {
        let player = ThemeSongPlayer(timings: ThemeSongTimings(startDelay: 0))
        PlaybackSettings.shared.playThemeSongs = true
        var resolverCalls = 0
        var urlBuilderCalls = 0
        player.resolver = { _ in resolverCalls += 1; return "theme-item-id" }
        let url = try themeURL()
        player.urlBuilder = { _ in urlBuilderCalls += 1; return url }
        player.isOtherAudioPlaying = { true }

        player.showAppeared(seriesId: "A")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(resolverCalls, 0, "a skipped visit must not cost a theme lookup")
        XCTAssertEqual(urlBuilderCalls, 0, "a skipped visit must not build a stream URL either")
        XCTAssertNil(player.playerForTest, "no AVPlayer may be created when another app owns the audio")
    }

    /// The other half of the pair. Without this, a gate that skipped
    /// unconditionally would still satisfy the test above — the exact shape
    /// of "passes against broken code" this feature has already been bitten
    /// by on other clients.
    func testNoOtherAudioLetsTheThemeStart() async throws {
        let player = ThemeSongPlayer(timings: ThemeSongTimings(startDelay: 0))
        PlaybackSettings.shared.playThemeSongs = true
        var urlBuilderCalls = 0
        player.resolver = { _ in "theme-item-id" }
        let url = try themeURL()
        player.urlBuilder = { _ in urlBuilderCalls += 1; return url }
        player.isOtherAudioPlaying = { false }

        player.showAppeared(seriesId: "A")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(urlBuilderCalls, 1, "with no competing audio the theme must resolve and start")
        XCTAssertNotNil(player.playerForTest, "an AVPlayer should have been created")
    }

    /// The gate lives *after* the start delay on purpose: a show the user
    /// flicks past is cancelled before the delay elapses and must ask no
    /// question at all — not of `AVAudioSession`, not of the server. Moving
    /// the check ahead of the sleep would make every scrolled-past row
    /// interrogate the audio session.
    func testShowFlickedPastNeverConsultsTheGate() async {
        let player = ThemeSongPlayer(timings: ThemeSongTimings(startDelay: 0.75))
        PlaybackSettings.shared.playThemeSongs = true
        var probeCalls = 0
        player.isOtherAudioPlaying = { probeCalls += 1; return false }
        player.resolver = { _ in "theme-item-id" }
        player.urlBuilder = { _ in nil }

        player.showAppeared(seriesId: "A")
        player.detailDismissed(seriesId: "A")
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(probeCalls, 0, "a visit abandoned inside the start delay must not probe the audio session")
    }

    /// tvOS has no Ring/Silent switch, configures its session once at launch
    /// in `SashimiApp`, and its theme behaviour is unchanged by this fix. The
    /// shipped probe must therefore be inert here — if someone ever makes the
    /// default `AVAudioSession.isOtherAudioPlaying` on every platform, tvOS
    /// starts silently dropping themes and this catches it.
    func testShippedProbeIsInertOnTVOS() {
        let player = ThemeSongPlayer()
        #if os(tvOS)
        XCTAssertFalse(player.isOtherAudioPlaying(), "the tvOS default must be a constant false")
        #else
        _ = player
        #endif
    }
}

/// `fade()`'s early-return path (taken when a fade is instant, i.e.
/// `duration <= 0`) must clear `fadeTimer`, not merely invalidate the timer
/// it points to. Left dangling, an already-enqueued tick from that
/// invalidated timer would pass the `fadeTimer === timer` identity guard in
/// the timer's own closure (added to prevent exactly this class of stale-
/// tick bug) and nudge volume after this "instant" fade already set it.
///
/// Unreachable through `play()` alone with shipped defaults, because `play()`
/// always tears down (and therefore clears `fadeTimer`) immediately before
/// its own fade call — there's nothing to dangle at that specific call site.
/// It becomes reachable the moment an instant fade (`duration <= 0`, e.g. an
/// injected `fadeIn: 0`, or any fade call that isn't preceded by a
/// synchronous teardown) runs while a real fade timer is still live — which
/// is exactly what `playForTest`/`fadeForTest` (added alongside this test)
/// let this suite construct deterministically, without waiting on a real
/// timer race.
@MainActor
final class ThemeSongFadeLifecycleTests: XCTestCase {
    func testImmediateFadeClearsAnyPriorTimerReference() throws {
        let player = ThemeSongPlayer(timings: ThemeSongTimings())
        // A reserved, non-routable address: AVPlayerItem/AVPlayer
        // construction and `play()` are local operations that don't need the
        // stream to actually resolve for this test.
        let url = try XCTUnwrap(URL(string: "http://192.0.2.1:1/unreachable-theme.mp3"))

        player.playForTest(url: url)
        XCTAssertNotNil(player.fadeTimerForTest, "sanity: play() should install a live fade-in timer")

        player.fadeForTest(to: 0, over: 0)
        XCTAssertNil(player.fadeTimerForTest, "an immediate fade must clear fadeTimer, not merely invalidate it")
    }

    /// `play()` tears down before doing anything else, specifically so a
    /// second `play()` before the first has finished can't strand the prior
    /// AVPlayer - the worst failure mode: two themes audible at once.
    ///
    /// `fadeTimerForTest.isValid` alone does **not** distinguish this fix
    /// from its absence: `fade(to:over:completion:)`, called unconditionally
    /// at the end of every `play()`, invalidates whatever the *current*
    /// `fadeTimer` is as its own first line - regardless of whether
    /// `teardown()` ran first. Confirmed by removing the `teardown()` call
    /// from `play()` and re-running: a timer-validity-only version of this
    /// test still passed, which is exactly the "passes either way" trap the
    /// review warned against. `player?.pause()`, by contrast, happens
    /// *only* inside `teardown()` - nothing else in `play()`/`fade()` ever
    /// pauses a player - so it's the assertion that actually exercises the
    /// fix. `playerForTest` (added alongside this test) exposes that.
    func testSecondPlayPausesTheFirstPlaysPlayer() throws {
        let player = ThemeSongPlayer(timings: ThemeSongTimings())
        let firstURL = try XCTUnwrap(URL(string: "http://192.0.2.1:1/first-theme.mp3"))
        let secondURL = try XCTUnwrap(URL(string: "http://192.0.2.1:1/second-theme.mp3"))

        player.playForTest(url: firstURL)
        let firstPlayer = try XCTUnwrap(player.playerForTest)
        let firstTimer = try XCTUnwrap(player.fadeTimerForTest)

        player.playForTest(url: secondURL)

        XCTAssertEqual(firstPlayer.rate, 0, "a second play() must pause the first play's AVPlayer, not strand it running")
        XCTAssertFalse(firstTimer.isValid, "the first play's fade-in timer should also no longer be valid")
    }

    /// The timer-identity guard inside the fade timer's own tick closure
    /// exists so a tick that has already fired - and been *enqueued* as a
    /// MainActor `Task`, not yet run - can't act on stale state by the time
    /// it's finally dequeued, if a newer fade replaced `fadeTimer` in the
    /// meantime. `Timer.fire()` triggers a timer's block synchronously
    /// without waiting on the real run loop, which is what makes this
    /// reproducible deterministically: fire the first fade's (single-step)
    /// timer to enqueue its tick's Task without running it, replace it with
    /// a second fade, then yield so the stale Task actually executes and
    /// can be observed failing its own identity check.
    func testStaleTimerTickCannotClobberANewerFade() async throws {
        let player = ThemeSongPlayer(timings: ThemeSongTimings())
        let url = try XCTUnwrap(URL(string: "http://192.0.2.1:1/unreachable-theme.mp3"))
        player.playForTest(url: url)

        var staleCompletionFired = false
        // A single-step fade (steps = max(1, 0.05/0.05) = 1): one `.fire()`
        // is its *last* tick, the one that would otherwise invalidate the
        // timer and run its completion.
        player.fadeForTest(to: 0.6, over: 0.05) { staleCompletionFired = true }
        let staleTimer = try XCTUnwrap(player.fadeTimerForTest)
        staleTimer.fire()

        var liveCompletionFired = false
        player.fadeForTest(to: 0, over: 1.0) { liveCompletionFired = true }
        let liveTimer = try XCTUnwrap(player.fadeTimerForTest)
        XCTAssertFalse(liveTimer === staleTimer, "sanity: the newer fade must be a different timer instance")

        // Let the stale tick's already-enqueued Task actually run. A short
        // sleep, not a wall-clock fade duration - the same "let async work
        // settle" pattern as `testDisabledSettingResolvesNothing` above.
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(player.fadeTimerForTest === liveTimer, "a stale tick must not nil out the newer fade's live timer")
        XCTAssertFalse(staleCompletionFired, "a stale tick must not fire the superseded fade's completion")
        XCTAssertFalse(liveCompletionFired, "the newer fade's own completion must not fire from someone else's tick")
    }
}

/// The `fadeOutEnding` gap this whole pass exists to fix started as a
/// `private let` no test ever read — declared, matching spec, and silently
/// wired to nothing. This suite reads every shipped default directly, and
/// exercises the end-fade boundary math without loading real audio.
final class ThemeSongTimingsTests: XCTestCase {
    func testShippedTimingsMatchSpec() {
        let timings = ThemeSongTimings()
        XCTAssertEqual(timings.startDelay, 0.75)
        XCTAssertEqual(timings.volume, 0.6)
        XCTAssertEqual(timings.fadeIn, 1.0)
        XCTAssertEqual(timings.fadeOutEnding, 1.5)
        XCTAssertEqual(timings.fadeOutShowChange, 0.4)
        XCTAssertEqual(timings.fadeOutHard, 0.25)
    }

    /// The player/trailer cut is deliberately the fastest transition
    /// available — the theme must be gone before the player's own audio
    /// starts.
    func testHardCutIsTheFastestFade() {
        let timings = ThemeSongTimings()
        XCTAssertLessThan(timings.fadeOutHard, timings.fadeOutShowChange)
        XCTAssertLessThan(timings.fadeOutHard, timings.fadeIn)
        XCTAssertLessThan(timings.fadeOutHard, timings.fadeOutEnding)
    }
}

@MainActor
final class ThemeSongEndFadeBoundaryTests: XCTestCase {
    func testBoundaryStartsFadeOutEndingBeforeTheEnd() {
        let boundary = ThemeSongPlayer.endFadeBoundary(duration: 30, fadeOutEnding: 1.5)
        XCTAssertEqual(boundary, 28.5)
    }

    /// A theme shorter than the fade must degrade to the existing abrupt
    /// stop at end-of-track, not a negative boundary or an immediate fade.
    func testThemeShorterThanTheFadeDegradesToNil() {
        XCTAssertNil(ThemeSongPlayer.endFadeBoundary(duration: 1.0, fadeOutEnding: 1.5))
    }

    /// A theme exactly as long as the fade also has no room for one - the
    /// boundary would land at (or before) the start of the track.
    func testThemeExactlyTheFadeLengthDegradesToNil() {
        XCTAssertNil(ThemeSongPlayer.endFadeBoundary(duration: 1.5, fadeOutEnding: 1.5))
    }

    /// `AVPlayerItem.duration` reads as indefinite (NaN) until the asset
    /// loads; an unfinished or unusable load must degrade the same way.
    func testUnusableDurationDegradesToNil() {
        XCTAssertNil(ThemeSongPlayer.endFadeBoundary(duration: .nan, fadeOutEnding: 1.5))
        XCTAssertNil(ThemeSongPlayer.endFadeBoundary(duration: .infinity, fadeOutEnding: 1.5))
    }
}
