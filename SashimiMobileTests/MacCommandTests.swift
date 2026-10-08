import UIKit
import XCTest
@testable import SashimiMobile

/// The Mac app's menu commands, keyboard shortcuts, window policy and layout
/// idiom. Pure logic: the menus and the player only bind to these.
final class MacCommandShortcutTests: XCTestCase {
    func testPlayerKeysAreUnmodified() {
        XCTAssertEqual(AppCommand.playPause.shortcut, CommandShortcut(key: .space))
        XCTAssertEqual(AppCommand.skip(seconds: -10).shortcut, CommandShortcut(key: .leftArrow))
        XCTAssertEqual(AppCommand.skip(seconds: 10).shortcut, CommandShortcut(key: .rightArrow))
        XCTAssertEqual(AppCommand.toggleFullScreen.shortcut, CommandShortcut(key: .character("f")))
        XCTAssertEqual(AppCommand.toggleMute.shortcut, CommandShortcut(key: .character("m")))
        XCTAssertEqual(AppCommand.toggleSubtitles.shortcut, CommandShortcut(key: .character("c")))
        XCTAssertEqual(AppCommand.escape.shortcut, CommandShortcut(key: .escape))
    }

    func testEpisodeAndNavigationShortcutsUseCommand() {
        XCTAssertEqual(
            AppCommand.nextEpisode.shortcut,
            CommandShortcut(key: .rightArrow, modifiers: [.command, .shift])
        )
        XCTAssertEqual(
            AppCommand.previousEpisode.shortcut,
            CommandShortcut(key: .leftArrow, modifiers: [.command, .shift])
        )
        XCTAssertEqual(AppCommand.search.shortcut, CommandShortcut(key: .character("f"), modifiers: [.command]))
        XCTAssertEqual(AppCommand.settings.shortcut, CommandShortcut(key: .character(","), modifiers: [.command]))
        XCTAssertEqual(AppCommand.railSection(3).shortcut, CommandShortcut(key: .character("3"), modifiers: [.command]))
        XCTAssertNil(AppCommand.railSection(10).shortcut)
        XCTAssertNil(AppCommand.railSection(0).shortcut)
    }

    /// Two menu items with one key equivalent: AppKit fires only the first.
    func testNoTwoCommandsShareAShortcut() {
        var commands: [AppCommand] = [
            .playPause, .skip(seconds: -10), .skip(seconds: 10), .nextEpisode, .previousEpisode,
            .toggleSubtitles, .toggleMute, .toggleFullScreen, .escape, .search, .settings
        ]
        commands += (1...9).map { AppCommand.railSection($0) }
        let shortcuts = commands.compactMap(\.shortcut)
        XCTAssertEqual(shortcuts.count, commands.count)
        XCTAssertEqual(Set(shortcuts).count, shortcuts.count)
    }

    func testOnlyPlayerCommandsArePlayerCommands() {
        XCTAssertTrue(AppCommand.playPause.isPlayerCommand)
        XCTAssertTrue(AppCommand.setQuality(.auto).isPlayerCommand)
        XCTAssertTrue(AppCommand.escape.isPlayerCommand)
        XCTAssertFalse(AppCommand.search.isPlayerCommand)
        XCTAssertFalse(AppCommand.settings.isPlayerCommand)
        XCTAssertFalse(AppCommand.railSection(1).isPlayerCommand)
    }

    func testEscapeLeavesFullScreenBeforeClosingThePlayer() {
        XCTAssertEqual(PlayerEscapeAction.forWindow(isFullScreen: true), .exitFullScreen)
        XCTAssertEqual(PlayerEscapeAction.forWindow(isFullScreen: false), .closePlayer)
    }
}

final class RailShortcutTests: XCTestCase {
    private func items(_ count: Int) -> [SidebarSelection] {
        (0..<count).map { .library(id: "\($0)", name: "L\($0)", collectionType: nil) }
    }

    func testShortRailNumbersEveryItem() {
        let rail = items(7)
        XCTAssertEqual(RailShortcut.selection(forShortcut: 1, in: rail), rail[0])
        XCTAssertEqual(RailShortcut.selection(forShortcut: 7, in: rail), rail[6])
        XCTAssertNil(RailShortcut.selection(forShortcut: 8, in: rail))
        XCTAssertNil(RailShortcut.selection(forShortcut: 9, in: rail))
    }

    /// ⌘9 is the last item (Settings) however long the rail is.
    func testLongRailGivesCommandNineToTheLastItem() {
        let rail = items(12)
        XCTAssertEqual(RailShortcut.selection(forShortcut: 8, in: rail), rail[7])
        XCTAssertEqual(RailShortcut.selection(forShortcut: 9, in: rail), rail[11])
        XCTAssertNil(RailShortcut.shortcutNumber(forIndex: 8, count: 12))
        XCTAssertEqual(RailShortcut.shortcutNumber(forIndex: 11, count: 12), 9)
    }

    func testMenuNumbersAndSelectionAgree() {
        for count in [1, 5, 8, 9, 10, 15] {
            let rail = items(count)
            for index in rail.indices {
                guard let number = RailShortcut.shortcutNumber(forIndex: index, count: count) else { continue }
                XCTAssertEqual(RailShortcut.selection(forShortcut: number, in: rail), rail[index], "count \(count)")
            }
        }
    }

    func testOutOfRangeShortcutsSelectNothing() {
        XCTAssertNil(RailShortcut.selection(forShortcut: 0, in: items(5)))
        XCTAssertNil(RailShortcut.selection(forShortcut: 10, in: items(15)))
        XCTAssertNil(RailShortcut.selection(forShortcut: 1, in: []))
    }

    /// The menu numbers the same list the rail draws.
    func testRailItemsAreHomeThenLibrariesThenSearchDownloadsSettings() {
        let libraries = [
            JellyfinLibrary(id: "movies", name: "Movies", collectionType: "movies", imageTags: nil),
            JellyfinLibrary(id: "tv", name: "TV", collectionType: "tvshows", imageTags: nil)
        ]
        let rows = [
            HomeRowConfig(type: .library(id: "tv", name: "TV"), isEnabled: true),
            HomeRowConfig(type: .builtIn(.channels), isEnabled: true)
        ]
        XCTAssertEqual(
            SidebarSelection.railItems(rowConfigs: rows, libraries: libraries),
            [
                .home,
                .library(id: "tv", name: "TV", collectionType: "tvshows"),
                .finTV,
                .library(id: "movies", name: "Movies", collectionType: "movies"),
                .search, .downloads, .settings
            ]
        )
    }
}

@MainActor
final class AppCommandCenterTests: XCTestCase {
    private let rail: [SidebarSelection] = [.home, .finTV, .search, .downloads, .settings]

    func testPlayerCommandsGoToThePlayerOnScreen() {
        let center = AppCommandCenter()
        var received: [AppCommand] = []
        center.registerPlayer(.init(id: UUID(), viewModel: nil) { received.append($0) })

        center.perform(.playPause)
        center.perform(.skip(seconds: 10))
        center.perform(.setQuality(.quality720p))

        XCTAssertEqual(received, [.playPause, .skip(seconds: 10), .setQuality(.quality720p)])
    }

    func testPlayerCommandsAreDisabledWithoutAPlayer() {
        let center = AppCommandCenter()
        XCTAssertFalse(center.isEnabled(.playPause))
        XCTAssertFalse(center.isEnabled(.escape))
        center.perform(.playPause) // no player: nothing to reach, nothing crashes
    }

    func testAStalePlayerCannotUnregisterItsReplacement() {
        let center = AppCommandCenter()
        let old = UUID()
        let new = UUID()
        center.registerPlayer(.init(id: old, viewModel: nil) { _ in })
        center.registerPlayer(.init(id: new, viewModel: nil) { _ in })

        center.unregisterPlayer(id: old)
        XCTAssertEqual(center.player?.id, new)

        center.unregisterPlayer(id: new)
        XCTAssertNil(center.player)
    }

    func testRailShortcutRequestsThatSection() throws {
        let center = AppCommandCenter()
        center.updateRailItems(rail)

        center.perform(.railSection(2))
        XCTAssertEqual(center.navigationRequest?.selection, .finTV)

        let request = try XCTUnwrap(center.navigationRequest)
        center.consumeNavigationRequest(id: request.id)
        XCTAssertNil(center.navigationRequest)
    }

    func testSearchAndSettingsRequests() {
        let center = AppCommandCenter()
        center.updateRailItems(rail)

        center.perform(.search)
        XCTAssertEqual(center.navigationRequest?.selection, .search)
        XCTAssertEqual(center.navigationRequest?.focusesSearch, true)

        center.perform(.settings)
        XCTAssertEqual(center.navigationRequest?.selection, .settings)
        XCTAssertEqual(center.navigationRequest?.focusesSearch, false)
    }

    /// No rail (signed out, or the iPhone's tabs): nothing to navigate.
    func testNavigationIsDisabledWithoutARail() {
        let center = AppCommandCenter()
        XCTAssertFalse(center.isEnabled(.search))
        XCTAssertFalse(center.isEnabled(.settings))
        center.perform(.railSection(1))
        XCTAssertNil(center.navigationRequest)
    }

    /// Navigating would happen behind the player; the player owns the keys.
    func testNavigationIsDisabledWhileAPlayerIsUp() {
        let center = AppCommandCenter()
        center.updateRailItems(rail)
        center.registerPlayer(.init(id: UUID(), viewModel: nil) { _ in })

        XCTAssertFalse(center.isEnabled(.search))
        XCTAssertFalse(center.isEnabled(.railSection(1)))
        center.perform(.settings)
        XCTAssertNil(center.navigationRequest)
    }
}

final class SubtitleToggleTests: XCTestCase {
    private let off = SubtitleTrackOption(id: "off", displayName: "Off", languageCode: nil, index: -1, isOffOption: true)
    private let english = SubtitleTrackOption(id: "2", displayName: "English", languageCode: "eng", index: 2, isOffOption: false)
    private let french = SubtitleTrackOption(id: "3", displayName: "French", languageCode: "fre", index: 3, isOffOption: false)

    func testOnTurnsOff() {
        XCTAssertEqual(
            SubtitleToggle.choice(tracks: [off, english], selectedID: "2", lastSelectedID: nil, preferredLanguage: ""),
            .off
        )
    }

    func testOffRestoresTheLastTrack() {
        XCTAssertEqual(
            SubtitleToggle.choice(tracks: [off, english, french], selectedID: "off", lastSelectedID: "3", preferredLanguage: "eng"),
            .track(id: "3")
        )
    }

    func testOffWithNoHistoryPrefersTheSettingsLanguageThenTheFirst() {
        XCTAssertEqual(
            SubtitleToggle.choice(tracks: [off, english, french], selectedID: nil, lastSelectedID: nil, preferredLanguage: "FRE"),
            .track(id: "3")
        )
        XCTAssertEqual(
            SubtitleToggle.choice(tracks: [off, english, french], selectedID: nil, lastSelectedID: nil, preferredLanguage: ""),
            .track(id: "2")
        )
    }

    /// A remembered track from the previous episode may not exist in this one.
    func testAMissingLastTrackFallsBack() {
        XCTAssertEqual(
            SubtitleToggle.choice(tracks: [off, english], selectedID: "off", lastSelectedID: "9", preferredLanguage: ""),
            .track(id: "2")
        )
    }

    func testNoTracksDoesNothing() {
        XCTAssertEqual(
            SubtitleToggle.choice(tracks: [off], selectedID: "off", lastSelectedID: nil, preferredLanguage: "eng"),
            .none
        )
    }
}

final class MacWindowAndIdiomTests: XCTestCase {
    func testDefaultFrameIsCentredOnALargeScreen() {
        let frame = MacWindowMetrics.initialFrame(in: CGRect(x: 0, y: 0, width: 1728, height: 1117))
        XCTAssertEqual(frame.size, MacWindowMetrics.defaultSize)
        XCTAssertEqual(frame.midX, 864, accuracy: 0.5)
        XCTAssertEqual(frame.midY, 558.5, accuracy: 0.5)
    }

    func testDefaultFrameShrinksToASmallScreenButNotBelowTheMinimum() {
        let small = MacWindowMetrics.initialFrame(in: CGRect(x: 0, y: 0, width: 1024, height: 700))
        XCTAssertEqual(small.size, CGSize(width: 1024, height: 700))

        let tiny = MacWindowMetrics.initialFrame(in: CGRect(x: 0, y: 0, width: 800, height: 500))
        XCTAssertEqual(tiny.size, MacWindowMetrics.minimumSize)
        XCTAssertEqual(tiny.origin, .zero)
    }

    func testMinimumIsBelowDefault() {
        XCTAssertLessThan(MacWindowMetrics.minimumSize.width, MacWindowMetrics.defaultSize.width)
        XCTAssertLessThan(MacWindowMetrics.minimumSize.height, MacWindowMetrics.defaultSize.height)
    }

    /// "Optimize for Mac" reports the .mac idiom; it must get the iPad
    /// layout (rail, iPad detail, iPad player), never the phone tabs.
    func testMacGetsThePadLayout() {
        XCTAssertTrue(MobileLayoutIdiom.usesPadLayout(.mac))
        XCTAssertTrue(MobileLayoutIdiom.usesPadLayout(.pad))
        XCTAssertFalse(MobileLayoutIdiom.usesPadLayout(.phone))
        XCTAssertFalse(MobileLayoutIdiom.usesPadLayout(.unspecified))
        XCTAssertEqual(AdaptiveDetailLayout.forDevice(idiom: .mac), .pad)
    }
}

final class ItemContextActionTests: XCTestCase {
    private func item(_ type: String, seriesId: String? = nil) throws -> BaseItemDto {
        var json: [String: Any] = ["Id": "item", "Name": "Item", "Type": type]
        if let seriesId { json["SeriesId"] = seriesId }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(BaseItemDto.self, from: data)
    }

    func testMovieOnlineOffersPlayDownloadAndChannelForAdmins() throws {
        XCTAssertEqual(
            ItemContextAction.available(for: try item("Movie"), isOnline: true, canManageChannels: true, hasDownload: false),
            [.play, .download, .addToChannel]
        )
        XCTAssertEqual(
            ItemContextAction.available(for: try item("Movie"), isOnline: true, canManageChannels: false, hasDownload: false),
            [.play, .download]
        )
    }

    func testDownloadedItemIsNotOfferedAgain() throws {
        XCTAssertEqual(
            ItemContextAction.available(for: try item("Episode"), isOnline: true, canManageChannels: false, hasDownload: true),
            [.play]
        )
    }

    func testOfflineOnlyADownloadPlays() throws {
        XCTAssertEqual(
            ItemContextAction.available(for: try item("Movie"), isOnline: false, canManageChannels: true, hasDownload: true),
            [.play]
        )
        XCTAssertEqual(
            ItemContextAction.available(for: try item("Movie"), isOnline: false, canManageChannels: true, hasDownload: false),
            []
        )
    }

    /// A series plays its next episode but is downloaded from its page.
    func testSeriesPlaysButIsNotDownloadedFromTheMenu() throws {
        XCTAssertEqual(
            ItemContextAction.available(for: try item("Series"), isOnline: true, canManageChannels: false, hasDownload: false),
            [.play]
        )
    }

    func testFoldersOfferNothing() throws {
        XCTAssertEqual(
            ItemContextAction.available(for: try item("BoxSet"), isOnline: true, canManageChannels: true, hasDownload: false),
            []
        )
    }
}
