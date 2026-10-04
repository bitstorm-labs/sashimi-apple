import XCTest
@testable import Sashimi

/// Only a genuine Jellyfin answer counts as "server reachable" (#605).
final class ReachabilityProbeResponseTests: XCTestCase {
    /// The shape the home server (Jellyfin 12.1.0) returns, with the id
    /// replaced.
    private let jellyfinBody = Data("""
    {"LocalAddress":"jellyfin.example","ServerName":"Home","Version":"12.1.0",\
    "ProductName":"Jellyfin Server","OperatingSystem":"",\
    "Id":"0123456789abcdef0123456789abcdef","StartupWizardCompleted":true}
    """.utf8)

    func testJellyfinPublicInfoIsReachable() {
        XCTAssertTrue(JellyfinClient.isJellyfinPublicInfoResponse(statusCode: 200, body: jellyfinBody))
    }

    func testCaptivePortalHTMLIsNotReachable() {
        let portal = Data("<html><head><title>Sign in to Wi-Fi</title></head><body>Accept terms</body></html>".utf8)
        XCTAssertFalse(JellyfinClient.isJellyfinPublicInfoResponse(statusCode: 200, body: portal))
    }

    func testOtherJSONIsNotReachable() {
        // A different service on the same host/port answering JSON.
        let other = Data(#"{"status":"ok","name":"router"}"#.utf8)
        XCTAssertFalse(JellyfinClient.isJellyfinPublicInfoResponse(statusCode: 200, body: other))
    }

    func testRedirectsAndAuthWallsAreNotReachable() {
        // A captive portal's 302/401/403 used to count (anything below 500).
        XCTAssertFalse(JellyfinClient.isJellyfinPublicInfoResponse(statusCode: 302, body: Data()))
        XCTAssertFalse(JellyfinClient.isJellyfinPublicInfoResponse(statusCode: 401, body: Data("Unauthorized".utf8)))
        XCTAssertFalse(JellyfinClient.isJellyfinPublicInfoResponse(statusCode: 404, body: Data("<html>404</html>".utf8)))
    }

    func testGatewayErrorIsNotReachable() {
        XCTAssertFalse(JellyfinClient.isJellyfinPublicInfoResponse(statusCode: 502, body: jellyfinBody))
    }

    func testEmptyIdIsNotReachable() {
        let body = Data(#"{"ServerName":"Home","Version":"12.1.0","Id":""}"#.utf8)
        XCTAssertFalse(JellyfinClient.isJellyfinPublicInfoResponse(statusCode: 200, body: body))
    }
}
