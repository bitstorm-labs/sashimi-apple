import Foundation

/// What Settings › Sign In a TV asks the server, as a protocol so the view
/// model is testable without one.
protocol QuickConnectApprovalClient: Sendable {
    func isQuickConnectEnabled() async -> Bool
    func authorizeQuickConnect(code: String) async throws -> Bool
}

extension JellyfinClient: QuickConnectApprovalClient {}

/// Settings › Sign In a TV (#801): enter the code a TV shows for Quick
/// Connect and approve it with this device's session, signing the TV in as
/// the same user on the same server.
@MainActor
final class QuickConnectApprovalViewModel: ObservableObject {
    enum Phase: Equatable {
        case entering
        case approving
        case approved
        case failed(String)
    }

    static let codeLength = 6
    static let notFoundMessage = "Code not found or expired"

    /// Digits only, at most six; editing after a result starts over.
    @Published var code = "" {
        didSet {
            let digits = String(code.filter(\.isASCIIDigit).prefix(Self.codeLength))
            if digits != code { code = digits }
            if code != oldValue, phase != .approving { phase = .entering }
        }
    }
    @Published private(set) var phase: Phase = .entering
    /// Whether to show the Settings row: true only when the server has
    /// Quick Connect enabled.
    @Published private(set) var isAvailable = false

    private let client: QuickConnectApprovalClient

    init(client: QuickConnectApprovalClient = JellyfinClient.shared) {
        self.client = client
    }

    var canApprove: Bool {
        code.count == Self.codeLength && phase != .approving
    }

    func refreshAvailability() async {
        let enabled = await client.isQuickConnectEnabled()
        guard !Task.isCancelled else { return }
        isAvailable = enabled
    }

    /// A clean screen each time it opens.
    func reset() {
        code = ""
        phase = .entering
    }

    func approve() async {
        guard canApprove else { return }
        phase = .approving
        do {
            let approved = try await client.authorizeQuickConnect(code: code)
            phase = approved ? .approved : .failed(Self.notFoundMessage)
        } catch {
            phase = .failed(Self.message(for: error))
        }
    }

    nonisolated static func message(for error: Error) -> String {
        switch error {
        // 404: no request with that code (never issued, or expired after
        // 10 minutes). 400: malformed code. 500: Jellyfin's answer for a code
        // that was already approved.
        case JellyfinError.httpError(statusCode: 404),
             JellyfinError.httpError(statusCode: 400),
             JellyfinError.httpError(statusCode: 500):
            return notFoundMessage
        case JellyfinError.invalidCredentials:
            return "The server refused the approval. Quick Connect may be turned off."
        default:
            return SignInFailure.message(for: error) ?? error.localizedDescription
        }
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
