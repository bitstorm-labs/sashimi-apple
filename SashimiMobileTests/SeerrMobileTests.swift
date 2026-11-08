import XCTest
@testable import SashimiMobile

/// The iPhone/iPad side of Seerr requests: Plex's web sign-in page instead
/// of a code, browser trailers, and the request titles the phone rows show.
@MainActor
final class SeerrMobileTests: XCTestCase {
    private final class MemoryCredentials: SeerrCredentialStore {
        var values: [String: String] = [:]
        func cookie(forKey key: String) -> String? { values[key] }
        func setCookie(_ cookie: String?, forKey key: String) { values[key] = cookie }
    }

    private func defaults() -> UserDefaults {
        let name = "seerr-mobile-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testAFreshInstallHasNoRequestServerUntilOneIsEntered() {
        let store = defaults()
        let session = SeerrSession(defaults: store, credentials: MemoryCredentials(), pollInterval: .zero)

        XCTAssertNil(session.serverURL)
        XCTAssertFalse(session.canSignIn)
        XCTAssertFalse(SeerrSession.canSignIn(serverText: ""))

        XCTAssertTrue(session.setServerAddress("requests.example.com"))
        let relaunched = SeerrSession(defaults: store, credentials: MemoryCredentials(), pollInterval: .zero)
        XCTAssertEqual(relaunched.serverURL?.absoluteString, "https://requests.example.com")
        XCTAssertTrue(relaunched.canSignIn)
    }

    func testPlexWebSignInUsesOneClientIdPerInstallAndComesBackToTheApp() throws {
        let store = defaults()
        let session = SeerrSession(defaults: store, credentials: MemoryCredentials(), pollInterval: .zero)

        let first = session.plexWebSignInURL(for: PlexPin(id: 1, code: "abc")).absoluteString
        let second = session.plexWebSignInURL(for: PlexPin(id: 2, code: "def")).absoluteString
        let relaunched = SeerrSession(defaults: store, credentials: MemoryCredentials(), pollInterval: .zero)
            .plexWebSignInURL(for: PlexPin(id: 3, code: "ghi")).absoluteString

        func clientID(_ url: String) -> String? {
            url.components(separatedBy: "clientID=").last?.components(separatedBy: "&").first
        }
        let id = try XCTUnwrap(clientID(first))
        XCTAssertFalse(id.isEmpty)
        XCTAssertEqual(clientID(second), id)
        XCTAssertEqual(clientID(relaunched), id)
        XCTAssertTrue(first.hasPrefix("https://app.plex.tv/auth/#!?"))
        XCTAssertTrue(first.contains("code=abc"))
        XCTAssertTrue(first.contains("forwardUrl=sashimi%3A%2F%2Fplex-auth"), "returns to the app's URL scheme")
    }

    func testTrailersOpenYouTubeOnTheWeb() {
        XCTAssertEqual(SeerrTrailer.url(key: "abc123")?.absoluteString, "https://www.youtube.com/watch?v=abc123")
    }

    func testShowRequestsNameTheirSeasons() {
        func row(_ seasons: [Int]?, kind: SeerrMediaKind = .tv) -> SeerrRequestRow {
            let request = SeerrRequest(
                id: 1,
                status: 1,
                type: kind,
                seasons: seasons?.map { SeerrSeasonRequest(seasonNumber: $0, status: 1) }
            )
            return SeerrRequestRow(id: 1, request: request, kind: kind, tmdbId: 9, title: "Dune: Prophecy",
                                   posterPath: nil, state: .pending, subtitle: "")
        }

        XCTAssertEqual(row([1]).displayTitle, "Dune: Prophecy · S1")
        XCTAssertEqual(row([3, 1, 2]).displayTitle, "Dune: Prophecy · S1–3")
        XCTAssertEqual(row([1, 4]).displayTitle, "Dune: Prophecy · 2 seasons")
        XCTAssertEqual(row(nil, kind: .movie).displayTitle, "Dune: Prophecy")
    }
}
