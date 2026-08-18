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
