import XCTest
@testable import SashimiMobile

final class SashimiMediaEntityQueryTests: XCTestCase {
    func testEntitiesForSkipsUnavailableServerAndReturnsResolvableEntities() async throws {
        let unavailable = SashimiMediaEntityIdentifier(
            serverID: "server-unavailable",
            itemID: "item-unavailable"
        )
        let available = (1...4).map { index in
            SashimiMediaEntityIdentifier(
                serverID: "server-available-\(index)",
                itemID: "item-available-\(index)"
            )
        }
        let expectedEntities = available.map { identifier in
            makeEntity(serverID: identifier.serverID, itemID: identifier.itemID)
        }
        let query = SashimiMediaEntityQuery { identifier in
            guard let index = available.firstIndex(of: identifier) else { return nil }
            return expectedEntities[index]
        }

        let identifiers = [unavailable] + available
        let entities = try await query.entities(for: identifiers.map { $0.rawValue })

        XCTAssertEqual(entities, expectedEntities)
    }

    func testEntitiesForSkipsMissingServerWithDefaultResolver() async throws {
        let identifier = SashimiMediaEntityIdentifier(
            serverID: "server-missing-\(UUID().uuidString)",
            itemID: "item-missing"
        )

        let entities = try await SashimiMediaEntityQuery().entities(for: [identifier.rawValue])

        XCTAssertTrue(entities.isEmpty)
    }

    func testEntitiesForPreservesInvalidIdentifierError() async {
        do {
            _ = try await SashimiMediaEntityQuery().entities(for: ["invalid-identifier"])
            XCTFail("Expected an invalid identifier error")
        } catch let error as SashimiMediaEntityQueryError {
            XCTAssertEqual(error, .invalidIdentifier)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEntitiesForPreservesAuthenticationError() async {
        let query = SashimiMediaEntityQuery { _ in
            throw SashimiMediaEntityQueryError.authenticationRequired
        }

        do {
            _ = try await query.entities(for: ["6:serveritem"])
            XCTFail("Expected an authentication error")
        } catch let error as SashimiMediaEntityQueryError {
            XCTAssertEqual(error, .authenticationRequired)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEntitiesForSkipsItemUnavailableAndContinues() async throws {
        let itemUnavailable = SashimiMediaEntityIdentifier(
            serverID: "server-available",
            itemID: "item-deleted"
        )
        let available = SashimiMediaEntityIdentifier(
            serverID: "server-available",
            itemID: "item-available"
        )
        let expectedEntity = makeEntity(
            serverID: available.serverID,
            itemID: available.itemID
        )
        let resolvingQuery = SashimiMediaEntityQuery { identifier in
            if identifier == itemUnavailable {
                throw SashimiMediaEntityQueryError.itemUnavailable
            }
            return expectedEntity
        }

        let entities = try await resolvingQuery.entities(for: [
            itemUnavailable.rawValue,
            available.rawValue
        ])

        XCTAssertEqual(entities, [expectedEntity])
    }

    func testEntitiesForHonorsCancellationBeforeResolution() async {
        let identifier = SashimiMediaEntityIdentifier(
            serverID: "server-cancelled",
            itemID: "item-cancelled"
        )
        let query = SashimiMediaEntityQuery { _ in nil }
        let task = Task {
            try await query.entities(for: [identifier.rawValue])
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation to be propagated")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeEntity(serverID: String, itemID: String) -> SashimiMediaEntity {
        let item = BaseItemDto(
            id: itemID, name: "Test Movie", type: .movie,
            seriesName: nil, seriesId: nil, seasonId: nil, parentId: nil,
            indexNumber: nil, parentIndexNumber: nil, overview: nil,
            runTimeTicks: nil, userData: nil, imageTags: nil,
            backdropImageTags: nil, parentBackdropImageTags: nil,
            primaryImageAspectRatio: nil, mediaType: nil, libraryName: nil,
            productionYear: 2026, communityRating: nil, officialRating: nil,
            genres: nil, taglines: nil, people: nil, criticRating: nil,
            premiereDate: nil, chapters: nil, path: nil, remoteTrailers: nil,
            localTrailerCount: nil, mediaStreams: nil
        )
        return SashimiMediaEntity(
            item: item,
            serverID: serverID,
            serverName: "Available Server"
        )
    }
}
