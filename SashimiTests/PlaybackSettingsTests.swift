import XCTest
@testable import Sashimi

/// `PlaybackSettings.defaultPlayThemeSongs(idiom:)` is the pure mapping
/// pulled out of the `@AppStorage("playThemeSongs")` initializer so it can be
/// exercised for every idiom without faking `UIDevice.current` (not
/// mockable) or a real `UserDefaults` suite. The property itself only reads
/// this default once, at first access, when nothing is already stored — that
/// part isn't under test here, just the idiom -> Bool logic that feeds it.
final class PlaybackSettingsDefaultThemeSongsTests: XCTestCase {
    func testPhoneDefaultsOff() {
        XCTAssertFalse(PlaybackSettings.defaultPlayThemeSongs(idiom: .phone))
    }

    func testPadDefaultsOn() {
        XCTAssertTrue(PlaybackSettings.defaultPlayThemeSongs(idiom: .pad))
    }

    /// The shipped tvOS default was `true` before this change; this pins
    /// that the idiom-derived expression doesn't regress it.
    func testTVDefaultsOnMatchingTheShippedTVOSDefault() {
        XCTAssertTrue(PlaybackSettings.defaultPlayThemeSongs(idiom: .tv))
    }

    /// This test host IS the tvOS app — `UIDevice.current.userInterfaceIdiom`
    /// really is `.tv` here, so calling the no-argument overload (the exact
    /// expression `@AppStorage` evaluates) exercises the production default
    /// end to end on the platform that shipped first, not just the pure
    /// function in isolation.
    func testRealDeviceIdiomOnThisTestHostDefaultsOn() {
        XCTAssertEqual(UIDevice.current.userInterfaceIdiom, .tv, "sanity: this suite runs in the tvOS host app")
        XCTAssertTrue(PlaybackSettings.defaultPlayThemeSongs())
    }

    /// Every other idiom (car display, Mac, unspecified, vision) should stay
    /// on too — only `.phone` is singled out.
    func testUnspecifiedAndOtherIdiomsDefaultOn() {
        XCTAssertTrue(PlaybackSettings.defaultPlayThemeSongs(idiom: .unspecified))
        XCTAssertTrue(PlaybackSettings.defaultPlayThemeSongs(idiom: .carPlay))
    }
}

/// Exercises the actual `@AppStorage("playThemeSongs")` wiring on
/// `PlaybackSettings` itself — not just the pure `defaultPlayThemeSongs`
/// function above. `PlaybackSettings` has an implicit internal `init`, and
/// `@AppStorage` outside a `View` reads/writes `UserDefaults.standard`
/// directly, so a fresh instance is enough to observe both halves of the
/// contract: the idiom-derived default applies when nothing is stored, and
/// a stored value always wins over it (an existing install's choice is
/// never silently overridden).
@MainActor
final class PlaybackSettingsAppStorageWiringTests: XCTestCase {
    private let key = "playThemeSongs"
    private var hadStoredValue = false
    private var previousValue = false

    override func setUp() {
        super.setUp()
        // Save whatever's there (if anything) so this suite can restore it
        // in tearDown and not leak state into other tests/suites that touch
        // the same UserDefaults.standard key.
        hadStoredValue = UserDefaults.standard.object(forKey: key) != nil
        if hadStoredValue {
            previousValue = UserDefaults.standard.bool(forKey: key)
        }
    }

    override func tearDown() {
        if hadStoredValue {
            UserDefaults.standard.set(previousValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    /// Exercises the real `@AppStorage` initializer end to end (not just the
    /// pure function it delegates to) — a fresh instance, nothing stored,
    /// must come up `true` on this host.
    ///
    /// Red-verify note: reverting `PlaybackSettings.swift`'s `playThemeSongs`
    /// declaration back to the old hardcoded `= true` does NOT fail this
    /// test. `.tv`'s idiom-derived default and the old hardcoded default are
    /// both `true`, and this suite only ever runs on the tvOS test host
    /// (`SashimiTests` has no iOS counterpart) — so no boolean read of
    /// `playThemeSongs` on this host can distinguish "computed from
    /// `defaultPlayThemeSongs()`" from "hardcoded `true`". Confirmed by
    /// actually doing that revert and rerunning: this test stayed green.
    /// The genuinely discriminating coverage for the idiom-dependent part of
    /// this change is `PlaybackSettingsDefaultThemeSongsTests.testPhoneDefaultsOff`
    /// / `testPadDefaultsOn` above, which pass the idiom in as an argument
    /// and don't depend on which platform hosts the test; both were
    /// red-verified successfully. This test is kept because "a fresh
    /// install defaults on" and "the `@AppStorage` wrapper itself works" are
    /// still real, worth-pinning facts — just not ones that isolate this
    /// specific wiring change on this host.
    func testFreshInstallUsesTheIdiomDerivedDefault() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertTrue(PlaybackSettings().playThemeSongs, "a fresh install on this (tvOS) host should default on")
    }

    /// A value already in `UserDefaults` — an existing install's explicit
    /// choice — must win over the idiom default, not be silently replaced
    /// by it.
    func testExistingStoredValueWinsOverTheDefault() {
        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(PlaybackSettings().playThemeSongs, "a stored value must not be overridden by the idiom default")
    }
}
