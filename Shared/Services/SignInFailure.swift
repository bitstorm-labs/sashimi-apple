import Foundation

/// Why a sign-in attempt failed, for the handful of cases the user can act on
/// differently (#476). An unreachable host, a refused connection, a rejected
/// certificate, a server too slow to answer and a wrong password used to read
/// alike; each now gets its own message.
///
/// Pure: classifies an error value and nothing else, so every case is unit
/// tested without a network. The copy matches the Roku and Android clients.
enum SignInFailure: Equatable, Sendable {
    case unreachable
    case connectionRefused
    case certificateRejected
    case timedOut
    case wrongCredentials

    var message: String {
        switch self {
        case .unreachable:
            return "Can't reach a server at that address. Check the address and that you're on the same network."
        case .connectionRefused:
            return "The server refused the connection. Check the port, and that Jellyfin is running."
        case .certificateRejected:
            return "The server's security certificate was rejected. Check whether the address should start with http:// or https://."
        case .timedOut:
            return "The server didn't answer within 12 seconds. It may be down or busy. Try again."
        case .wrongCredentials:
            return "Wrong username or password."
        }
    }

    /// The specific message for `error`, or nil when it is none of the cases
    /// above — the caller then shows whatever it showed before.
    static func message(for error: Error) -> String? {
        classify(error)?.message
    }

    static func classify(_ error: Error) -> SignInFailure? {
        if let jellyfinError = error as? JellyfinError {
            switch jellyfinError {
            case .invalidCredentials:
                // The auth request maps both 401 and 403 here.
                return .wrongCredentials
            case .networkError(let underlying):
                return classify(underlying)
            default:
                return nil
            }
        }
        guard (error as NSError).domain == NSURLErrorDomain else { return nil }
        return classify(urlErrorCode: URLError.Code(rawValue: (error as NSError).code), error: error)
    }

    private static func classify(urlErrorCode code: URLError.Code, error: Error) -> SignInFailure? {
        switch code {
        case .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet:
            return .unreachable
        case .cannotConnectToHost:
            return isConnectionRefused(error) ? .connectionRefused : .unreachable
        case .secureConnectionFailed,
             .serverCertificateHasBadDate,
             .serverCertificateUntrusted,
             .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid,
             .clientCertificateRejected,
             .clientCertificateRequired:
            return .certificateRejected
        case .timedOut:
            return .timedOut
        default:
            return nil
        }
    }

    /// `NSURLErrorCannotConnectToHost` covers both "nothing answered" and "the
    /// host answered with a reset". A refusal carries POSIX `ECONNREFUSED`,
    /// either as the CFNetwork stream-error keys on the error itself (what
    /// URLSession reports today) or as an underlying POSIX error.
    private static func isConnectionRefused(_ error: Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ECONNREFUSED) {
                return true
            }
            let streamDomain = nsError.userInfo[streamErrorDomainKey] as? Int
            let streamCode = nsError.userInfo[streamErrorCodeKey] as? Int
            if streamDomain == posixStreamErrorDomain, streamCode == Int(ECONNREFUSED) {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }

    static let streamErrorDomainKey = "_kCFStreamErrorDomainKey"
    static let streamErrorCodeKey = "_kCFStreamErrorCodeKey"
    /// `kCFStreamErrorDomainPOSIX`.
    static let posixStreamErrorDomain = 1
}
