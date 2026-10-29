import Foundation

/// A pending Quick Connect request (`POST /QuickConnect/Initiate`,
/// `GET /QuickConnect/Connect`). `Code` is what the user types on the device
/// that approves; `Secret` stays on this device and later trades for a
/// session through `POST /Users/AuthenticateWithQuickConnect`.
struct QuickConnectResult: Codable, Equatable {
    let secret: String
    let code: String
    let authenticated: Bool

    enum CodingKeys: String, CodingKey {
        case secret = "Secret"
        case code = "Code"
        case authenticated = "Authenticated"
    }
}
