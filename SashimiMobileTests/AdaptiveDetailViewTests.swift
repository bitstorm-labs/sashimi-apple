import UIKit
import XCTest
@testable import SashimiMobile

final class AdaptiveDetailViewTests: XCTestCase {
    func testAdaptiveViewBodyUsesPhoneDetailAndPropagatesServerID() throws {
        let content = try XCTUnwrap(
            AdaptiveDetailView(
                item: Self.makeItem(),
                serverID: "server-one",
                deviceIdiom: .phone
            ).body as? AdaptiveDetailContent
        )

        guard case .phone(let detailView) = content else {
            return XCTFail("Expected the production adaptive body to select PhoneDetailView")
        }

        XCTAssertEqual(content.layout, .phone)
        XCTAssertEqual(detailView.serverID, "server-one")
    }

    func testAdaptiveViewBodyUsesPadDetailAndPropagatesServerID() throws {
        let content = try XCTUnwrap(
            AdaptiveDetailView(
                item: Self.makeItem(),
                serverID: "server-one",
                deviceIdiom: .pad
            ).body as? AdaptiveDetailContent
        )

        guard case .pad(let detailView) = content else {
            return XCTFail("Expected the production adaptive body to select MobileDetailView")
        }

        XCTAssertEqual(content.layout, .pad)
        XCTAssertEqual(detailView.serverID, "server-one")
    }

    /// A season opens the season page (#760), laid out for the device.
    func testASeasonOpensTheSeasonPage() throws {
        for idiom in [UIUserInterfaceIdiom.phone, .pad] {
            let content = try XCTUnwrap(
                AdaptiveDetailView(
                    item: Self.makeItem(type: .season),
                    serverID: "server-one",
                    deviceIdiom: idiom
                ).body as? AdaptiveDetailContent
            )
            guard case .season(let seasonView) = content else {
                return XCTFail("Expected a season to open MobileSeasonView on \(idiom)")
            }
            XCTAssertEqual(seasonView.serverID, "server-one")
            XCTAssertEqual(content.layout, idiom == .pad ? .pad : .phone)
        }
    }

    func testUnknownIdiomsKeepThePhoneLayoutFallback() {
        XCTAssertEqual(AdaptiveDetailLayout.forDevice(idiom: .unspecified), .phone)
    }

    private static func makeItem(type: ItemType = .movie) -> BaseItemDto {
        BaseItemDto(
            id: "test-item",
            name: "Test Item",
            type: type,
            seriesName: nil,
            seriesId: type == .season ? "test-series" : nil,
            seasonId: nil,
            parentId: nil,
            indexNumber: nil,
            parentIndexNumber: nil,
            overview: nil,
            runTimeTicks: nil,
            userData: nil,
            imageTags: nil,
            backdropImageTags: nil,
            parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil,
            mediaType: nil,
            libraryName: nil,
            productionYear: nil,
            communityRating: nil,
            officialRating: nil,
            genres: nil,
            taglines: nil,
            people: nil,
            criticRating: nil,
            premiereDate: nil,
            chapters: nil,
            path: nil,
            remoteTrailers: nil,
            localTrailerCount: nil,
            mediaStreams: nil
        )
    }
}
