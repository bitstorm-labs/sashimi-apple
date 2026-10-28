import UIKit
import XCTest
@testable import SashimiMobile

/// #781: Play in an episode sheet on the Mac played inside the sheet, and an
/// episode card opened a small sheet instead of the episode's page.
final class PlayerHandoffTests: XCTestCase {
    // MARK: Where the player is presented from

    func testOutsideASheetThePlayerIsPresentedHere() {
        XCTAssertEqual(PlayerPresentationRoute.route(insideSheet: false), .presentHere)
    }

    /// A cover presented from a sheet's content stays inside the sheet.
    func testInsideASheetThePlayerIsHandedToThePresenter() {
        XCTAssertEqual(PlayerPresentationRoute.route(insideSheet: true), .handOffToPresenter)
    }

    func testThePresenterPlaysTheRequestOnceTheSheetHasGone() throws {
        var state = SheetPlayerHandoffState()
        let request = PlayerRequest(item: try Self.episode(), serverID: "server-one", startFromBeginning: true)
        state.receive(request)

        let next = try XCTUnwrap(state.sheetDidDismiss(presenterIsInSheet: false))
        XCTAssertEqual(next.route, .presentHere)
        XCTAssertEqual(next.request.id, request.id)
        XCTAssertEqual(next.request.item.id, "episode-3")
        XCTAssertEqual(next.request.serverID, "server-one")
        XCTAssertTrue(next.request.startFromBeginning)
    }

    /// A sheet shown from another sheet passes the request up, so the player
    /// still ends up over the whole window.
    func testANestedSheetPassesTheRequestUp() throws {
        var state = SheetPlayerHandoffState()
        state.receive(PlayerRequest(item: try Self.episode()))
        XCTAssertEqual(state.sheetDidDismiss(presenterIsInSheet: true)?.route, .handOffToPresenter)
    }

    /// Closing the sheet with Esc or a click outside plays nothing.
    func testASheetClosedWithoutPlayStartsNothing() {
        var state = SheetPlayerHandoffState()
        XCTAssertNil(state.sheetDidDismiss(presenterIsInSheet: false))
    }

    func testARequestIsPlayedOnlyOnce() throws {
        var state = SheetPlayerHandoffState()
        state.receive(PlayerRequest(item: try Self.episode()))
        XCTAssertNotNil(state.sheetDidDismiss(presenterIsInSheet: false))
        XCTAssertNil(state.sheetDidDismiss(presenterIsInSheet: false))
        XCTAssertNil(state.pending)
    }

    // MARK: Push vs sheet

    func testTheMacPushesTheEpisodePage() {
        XCTAssertEqual(EpisodeOpenStyle.forDevice(idiom: .mac), .push)
    }

    func testTheIPadPushesTheEpisodePage() {
        XCTAssertEqual(EpisodeOpenStyle.forDevice(idiom: .pad), .push)
    }

    func testTheIPhoneKeepsItsEpisodeSheet() {
        XCTAssertEqual(EpisodeOpenStyle.forDevice(idiom: .phone), .sheet)
    }

    private static func episode() throws -> BaseItemDto {
        let json = #"{"Id":"episode-3","Name":"Past and Present","Type":"Episode","IndexNumber":3}"#
        return try JSONDecoder().decode(BaseItemDto.self, from: Data(json.utf8))
    }
}
