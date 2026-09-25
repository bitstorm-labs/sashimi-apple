import XCTest
@testable import Sashimi

/// Sign-in failure classification and the short sign-in network path (#476).
final class SignInFailureTests: XCTestCase {

    // MARK: - Copy (shared verbatim with the Roku and Android clients)

    func testMessagesMatchTheCrossClientCopy() {
        XCTAssertEqual(
            SignInFailure.unreachable.message,
            "Can't reach a server at that address. Check the address and that you're on the same network."
        )
        XCTAssertEqual(
            SignInFailure.connectionRefused.message,
            "The server refused the connection. Check the port, and that Jellyfin is running."
        )
        XCTAssertEqual(
            SignInFailure.certificateRejected.message,
            "The server's security certificate was rejected. Check whether the address should start with http:// or https://."
        )
        XCTAssertEqual(
            SignInFailure.timedOut.message,
            "The server didn't answer within 12 seconds. It may be down or busy. Try again."
        )
        XCTAssertEqual(SignInFailure.wrongCredentials.message, "Wrong username or password.")
    }

    // MARK: - Unreachable

    func testHostNotFoundIsUnreachable() {
        XCTAssertEqual(SignInFailure.classify(URLError(.cannotFindHost)), .unreachable)
    }

    func testDNSLookupFailureIsUnreachable() {
        XCTAssertEqual(SignInFailure.classify(URLError(.dnsLookupFailed)), .unreachable)
    }

    func testNotConnectedToInternetIsUnreachable() {
        XCTAssertEqual(SignInFailure.classify(URLError(.notConnectedToInternet)), .unreachable)
    }

    func testCannotConnectWithoutARefusalIsUnreachable() {
        XCTAssertEqual(SignInFailure.classify(URLError(.cannotConnectToHost)), .unreachable)
    }

    func testCannotConnectWithAnotherPOSIXErrorIsUnreachable() {
        let error = URLError(.cannotConnectToHost, userInfo: [
            SignInFailure.streamErrorDomainKey: SignInFailure.posixStreamErrorDomain,
            SignInFailure.streamErrorCodeKey: Int(EHOSTUNREACH)
        ])
        XCTAssertEqual(SignInFailure.classify(error), .unreachable)
    }

    // MARK: - Refused

    /// The shape URLSession actually reports for a closed port (observed
    /// against a loopback port with nothing listening).
    func testCannotConnectWithStreamECONNREFUSEDIsRefused() {
        let error = URLError(.cannotConnectToHost, userInfo: [
            SignInFailure.streamErrorDomainKey: SignInFailure.posixStreamErrorDomain,
            SignInFailure.streamErrorCodeKey: Int(ECONNREFUSED)
        ])
        XCTAssertEqual(SignInFailure.classify(error), .connectionRefused)
    }

    func testCannotConnectWithUnderlyingPOSIXRefusalIsRefused() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        let error = URLError(.cannotConnectToHost, userInfo: [NSUnderlyingErrorKey: posix])
        XCTAssertEqual(SignInFailure.classify(error), .connectionRefused)
    }

    /// A refusal from a real socket, not a hand-built error: loopback port 1
    /// has nothing listening, so the connection is refused immediately.
    func testRealRefusedConnectionIsClassifiedAsRefused() async throws {
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:1/System/Info/Public"))
        let session = SignInNetworking.makeSession()
        do {
            _ = try await session.data(from: url)
            XCTFail("Expected the connection to be refused")
        } catch {
            XCTAssertEqual(SignInFailure.classify(error), .connectionRefused, "\(error)")
        }
    }

    /// The sign-in probe is a GET, which the general request path retries
    /// three times with backoff (1s + 2s + 4s) on a network error. Sign-in
    /// must report the refusal straight away instead.
    func testSignInProbeIsNotRetried() async throws {
        let client = JellyfinClient()
        await client.configure(serverURL: try XCTUnwrap(URL(string: "http://127.0.0.1:1")))
        let start = Date()
        do {
            _ = try await client.getPublicSystemInfo()
            XCTFail("Expected the connection to be refused")
        } catch {
            XCTAssertEqual(SignInFailure.classify(error), .connectionRefused, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    // MARK: - Certificate

    func testTLSFailuresAreCertificateRejections() {
        let codes: [URLError.Code] = [
            .secureConnectionFailed,
            .serverCertificateHasBadDate,
            .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
            .clientCertificateRejected,
            .clientCertificateRequired
        ]
        for code in codes {
            XCTAssertEqual(SignInFailure.classify(URLError(code)), .certificateRejected, "\(code)")
        }
    }

    /// Our trust policy rejects a certificate by cancelling the challenge,
    /// which URLSession reports as `cancelled`. That must read as a
    /// certificate failure, not as the user pressing Cancel.
    func testTrustRejectionSurfacesAsCertificateFailure() {
        let translated = SignInNetworking.translate(URLError(.cancelled), trustRejected: true)
        XCTAssertEqual(SignInFailure.classify(translated), .certificateRejected)
    }

    func testPlainCancellationStaysACancellation() {
        let translated = SignInNetworking.translate(URLError(.cancelled), trustRejected: false)
        XCTAssertEqual((translated as? URLError)?.code, .cancelled)
        XCTAssertNil(SignInFailure.classify(translated))
    }

    // MARK: - Timeout

    func testTimeoutIsTimedOut() {
        XCTAssertEqual(SignInFailure.classify(URLError(.timedOut)), .timedOut)
    }

    // MARK: - Credentials

    /// `JellyfinClient.request` turns a 401 on the auth request into
    /// `invalidCredentials`.
    func testRejectedCredentialsAreWrongCredentials() {
        XCTAssertEqual(SignInFailure.classify(JellyfinError.invalidCredentials), .wrongCredentials)
        XCTAssertEqual(
            SignInFailure.message(for: JellyfinError.invalidCredentials),
            "Wrong username or password."
        )
    }

    // MARK: - Wrapping and fall-through

    func testNetworkErrorsWrappedByTheClientAreUnwrapped() {
        XCTAssertEqual(
            SignInFailure.classify(JellyfinError.networkError(URLError(.timedOut))),
            .timedOut
        )
        XCTAssertEqual(
            SignInFailure.classify(JellyfinError.networkError(URLError(.cannotFindHost))),
            .unreachable
        )
    }

    func testOtherErrorsKeepTheirExistingMessage() {
        let others: [Error] = [
            URLError(.networkConnectionLost),
            URLError(.cancelled),
            URLError(.appTransportSecurityRequiresSecureConnection),
            JellyfinError.httpError(statusCode: 500),
            JellyfinError.decodingError,
            JellyfinError.invalidResponse,
            SessionError.duplicateServer,
            CancellationError()
        ]
        for error in others {
            XCTAssertNil(SignInFailure.classify(error), "\(error)")
            XCTAssertNil(SignInFailure.message(for: error), "\(error)")
        }
    }

    // MARK: - The sign-in session

    func testSignInSessionFailsFastInsteadOfWaiting() {
        let config = SignInNetworking.makeConfiguration()
        XCTAssertFalse(config.waitsForConnectivity)
        XCTAssertEqual(config.timeoutIntervalForRequest, 12)
        XCTAssertEqual(config.timeoutIntervalForResource, 12)
        XCTAssertEqual(SignInNetworking.budget, 12)
    }
}
