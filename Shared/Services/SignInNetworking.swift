import Foundation

/// The short-budget network path used only while signing in (#476).
///
/// The general browsing session waits for connectivity and allows a 120s
/// resource timeout, which is right for riding out a brief drop but left the
/// sign-in screen spinning for two minutes against a wrong address. Sign-in is
/// the opposite trade: the user is watching and can retry, so each step gets a
/// fixed budget, never waits for connectivity and is never retried.
enum SignInNetworking {
    /// Per-step budget, in seconds, for each sign-in request.
    static let budget: TimeInterval = 12

    static func makeConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = budget
        config.timeoutIntervalForResource = budget
        config.waitsForConnectivity = false
        config.urlCache = nil
        return config
    }

    /// No session delegate on purpose: certificate challenges go to the
    /// per-request `SignInTrustDelegate`, which can tell a trust rejection
    /// apart from a cancellation.
    static func makeSession() -> URLSession {
        URLSession(configuration: makeConfiguration())
    }

    /// Sends one sign-in request under the shared certificate-trust policy.
    static func data(
        for request: URLRequest,
        session: URLSession,
        trustPolicy: CertificateValidationDelegate
    ) async throws -> (Data, URLResponse) {
        let trustDelegate = SignInTrustDelegate(trustPolicy: trustPolicy)
        do {
            return try await session.data(for: request, delegate: trustDelegate)
        } catch {
            throw translate(error, trustRejected: trustDelegate.didRejectServerTrust)
        }
    }

    /// Rejecting a certificate in the challenge handler surfaces as
    /// `URLError.cancelled`, which would otherwise read as the user pressing
    /// Cancel. Report it as the certificate failure it is.
    static func translate(_ error: Error, trustRejected: Bool) -> Error {
        guard trustRejected,
              let urlError = error as? URLError,
              urlError.code == .cancelled else { return error }
        return URLError(.serverCertificateUntrusted)
    }
}

/// Applies `CertificateValidationDelegate`'s trust policy to one request and
/// records whether it rejected the server's certificate.
final class SignInTrustDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let trustPolicy: CertificateValidationDelegate
    private let lock = NSLock()
    private var rejected = false

    init(trustPolicy: CertificateValidationDelegate) {
        self.trustPolicy = trustPolicy
    }

    var didRejectServerTrust: Bool {
        lock.lock()
        defer { lock.unlock() }
        return rejected
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let isServerTrust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
        trustPolicy.urlSession(session, didReceive: challenge) { disposition, credential in
            if isServerTrust, disposition == .cancelAuthenticationChallenge {
                self.markRejected()
            }
            completionHandler(disposition, credential)
        }
    }

    private func markRejected() {
        lock.lock()
        rejected = true
        lock.unlock()
    }
}
