import XCTest
@testable import SashimiMobile

/// A scripted Quick Connect server: each poll takes the next scripted answer
/// (the last one repeats).
private actor StubQuickConnect: QuickConnectService {
    private let enabled: Bool
    private var answers: [Result<Bool, Error>]
    private(set) var signedInSecrets: [String] = []

    init(enabled: Bool = true, answers: [Result<Bool, Error>] = [.success(false)]) {
        self.enabled = enabled
        self.answers = answers
    }

    func isEnabled(serverURL: URL) async -> Bool { enabled }

    func initiate(serverURL: URL) async throws -> QuickConnectResult {
        QuickConnectResult(secret: "secret", code: "482917", authenticated: false)
    }

    func state(serverURL: URL, secret: String) async throws -> QuickConnectResult {
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        return QuickConnectResult(secret: secret, code: "482917", authenticated: try answer.get())
    }

    func signIn(serverURL: URL, secret: String) async throws {
        signedInSecrets.append(secret)
    }
}

/// The iPhone/iPad/Mac sign-in offers Quick Connect (#901): the button, the
/// code screen for each phase, and the full approve-then-sign-in flow.
@MainActor
final class MobileQuickConnectTests: XCTestCase {
    private let server = URL(string: "http://jellyfin.test:8096") ?? URL(fileURLWithPath: "/")

    private func waitUntil(
        _ condition: @autoclosure () -> Bool,
        timeout: Duration = .seconds(3),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                XCTFail("condition not met within \(timeout)", file: file, line: line)
                return
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    // MARK: - Offering the button

    func testOfferedOnceTheServerIsKnownAndHasItOn() {
        XCTAssertTrue(MobileQuickConnect.offersButton(isAvailable: true, serverURL: server, isSigningIn: false))
    }

    func testNotOfferedWhenTheServerHasItOff() {
        XCTAssertFalse(MobileQuickConnect.offersButton(isAvailable: false, serverURL: server, isSigningIn: false))
    }

    func testNotOfferedBeforeAServerIsConnected() {
        XCTAssertFalse(MobileQuickConnect.offersButton(isAvailable: true, serverURL: nil, isSigningIn: false))
    }

    func testNotOfferedWhileAPasswordSignInIsRunning() {
        XCTAssertFalse(MobileQuickConnect.offersButton(isAvailable: true, serverURL: server, isSigningIn: true))
    }

    // MARK: - What each phase shows

    func testRequestingShowsAProgressStatusAndNoCode() {
        let content = MobileQuickConnect.Content(phase: .requesting)
        XCTAssertNil(content.code)
        XCTAssertEqual(content.status, "Getting a code…")
        XCTAssertNil(content.retryTitle)
    }

    func testWaitingShowsTheSpacedCodeAndHowToApproveIt() {
        let content = MobileQuickConnect.Content(phase: .waiting(code: "482917"))
        XCTAssertEqual(content.code, "4 8 2 9 1 7")
        XCTAssertEqual(content.status, "Waiting for approval…")
        XCTAssertNotNil(content.instructions)
        XCTAssertNil(content.message)
        XCTAssertNil(content.retryTitle)
    }

    func testApprovedShowsSigningIn() {
        XCTAssertEqual(MobileQuickConnect.Content(phase: .signingIn).status, "Signing in…")
        XCTAssertEqual(MobileQuickConnect.Content(phase: .signedIn).status, "Signing in…")
    }

    func testExpiredOffersANewCode() {
        let content = MobileQuickConnect.Content(phase: .expired)
        XCTAssertNil(content.code)
        XCTAssertNil(content.status)
        XCTAssertEqual(content.message, "Code expired")
        XCTAssertEqual(content.tone, .warning)
        XCTAssertEqual(content.retryTitle, "Get New Code")
    }

    func testFailureShowsTheReasonAndOffersARetry() {
        let content = MobileQuickConnect.Content(phase: .failed("Quick Connect is turned off on this server."))
        XCTAssertEqual(content.message, "Quick Connect is turned off on this server.")
        XCTAssertEqual(content.tone, .error)
        XCTAssertEqual(content.retryTitle, "Try Again")
    }

    // MARK: - The flow the iOS sign-in drives

    func testApprovedCodeSignsInAndCompletesTheSheet() async {
        let stub = StubQuickConnect(answers: [.success(false), .success(true)])
        let viewModel = QuickConnectViewModel(service: stub, pollInterval: .milliseconds(10))
        var completions = 0
        viewModel.onSignedIn = { completions += 1 }

        await viewModel.refreshAvailability(for: server)
        XCTAssertTrue(MobileQuickConnect.offersButton(
            isAvailable: viewModel.isAvailable, serverURL: server, isSigningIn: false
        ))

        viewModel.start(serverURL: server)
        await waitUntil(MobileQuickConnect.Content(phase: viewModel.phase).code != nil)
        XCTAssertEqual(MobileQuickConnect.Content(phase: viewModel.phase).code, "4 8 2 9 1 7")

        await waitUntil(viewModel.phase == .signedIn)
        XCTAssertEqual(completions, 1)
        let secrets = await stub.signedInSecrets
        XCTAssertEqual(secrets, ["secret"])
    }

    func testServerWithQuickConnectOffHidesTheButton() async {
        let viewModel = QuickConnectViewModel(service: StubQuickConnect(enabled: false))
        await viewModel.refreshAvailability(for: server)
        XCTAssertFalse(MobileQuickConnect.offersButton(
            isAvailable: viewModel.isAvailable, serverURL: server, isSigningIn: false
        ))
    }
}
