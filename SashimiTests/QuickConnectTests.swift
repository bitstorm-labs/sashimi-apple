import XCTest
@testable import Sashimi

/// A scripted Quick Connect server: each poll takes the next scripted answer
/// (the last one repeats), and every call is counted.
private actor StubQuickConnect: QuickConnectService {
    private let enabled: Bool
    private let code: String
    private var answers: [Result<Bool, Error>]
    private let signInError: Error?

    private(set) var enabledCalls = 0
    private(set) var initiateCalls = 0
    private(set) var stateCalls = 0
    private(set) var signedInSecrets: [String] = []

    init(enabled: Bool = true, code: String = "482917", answers: [Result<Bool, Error>] = [.success(false)], signInError: Error? = nil) {
        self.enabled = enabled
        self.code = code
        self.answers = answers
        self.signInError = signInError
    }

    var totalCalls: Int { enabledCalls + initiateCalls + stateCalls + signedInSecrets.count }

    func isEnabled(serverURL: URL) async -> Bool {
        enabledCalls += 1
        return enabled
    }

    func initiate(serverURL: URL) async throws -> QuickConnectResult {
        initiateCalls += 1
        return QuickConnectResult(secret: "secret-\(initiateCalls)", code: code, authenticated: false)
    }

    func state(serverURL: URL, secret: String) async throws -> QuickConnectResult {
        stateCalls += 1
        let answer = answers.count > 1 ? answers.removeFirst() : answers[0]
        let authenticated = try answer.get()
        return QuickConnectResult(secret: secret, code: code, authenticated: authenticated)
    }

    func signIn(serverURL: URL, secret: String) async throws {
        signedInSecrets.append(secret)
        if let signInError { throw signInError }
    }
}

@MainActor
final class QuickConnectTests: XCTestCase {
    private let server = URL(string: "http://jellyfin.test:8096")
    private let interval = Duration.milliseconds(10)

    private func model(_ stub: StubQuickConnect, failures: Int = 5) -> QuickConnectViewModel {
        QuickConnectViewModel(service: stub, pollInterval: interval, maxConsecutiveFailures: failures)
    }

    /// Waits on the condition itself, not a fixed delay.
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

    // MARK: - Approved

    func testApprovedRequestSignsInWithItsSecret() async throws {
        let stub = StubQuickConnect(answers: [.success(false), .success(false), .success(true)])
        let viewModel = model(stub)
        var completions = 0
        viewModel.onSignedIn = { completions += 1 }

        viewModel.start(serverURL: try XCTUnwrap(server))
        await waitUntil(viewModel.phase == .signedIn)

        let secrets = await stub.signedInSecrets
        let polls = await stub.stateCalls
        XCTAssertEqual(secrets, ["secret-1"], "signs in once, with the secret Initiate returned")
        XCTAssertEqual(polls, 3, "polls until the third answer says Authenticated")
        XCTAssertEqual(completions, 1)
    }

    func testCodeIsShownWhileWaiting() async throws {
        let stub = StubQuickConnect(code: "482917")
        let viewModel = model(stub)

        viewModel.start(serverURL: try XCTUnwrap(server))
        await waitUntil(viewModel.phase == .waiting(code: "482917"))
        XCTAssertTrue(viewModel.isActive)
        viewModel.cancel()
    }

    func testSpacedCodeSeparatesEachDigit() {
        XCTAssertEqual(QuickConnectViewModel.spaced("482917"), "4 8 2 9 1 7")
    }

    // MARK: - Expired

    func testExpiredRequestStopsPollingAndOffersANewCode() async throws {
        let stub = StubQuickConnect(answers: [.success(false), .failure(QuickConnectError.expired)])
        let viewModel = model(stub)

        viewModel.start(serverURL: try XCTUnwrap(server))
        await waitUntil(viewModel.phase == .expired)
        let pollsAtExpiry = await stub.stateCalls

        // Several poll intervals later nothing else has been asked.
        try await Task.sleep(for: .milliseconds(100))
        let pollsLater = await stub.stateCalls
        let signIns = await stub.signedInSecrets
        XCTAssertEqual(pollsAtExpiry, 2)
        XCTAssertEqual(pollsLater, pollsAtExpiry, "no polling after expiry")
        XCTAssertTrue(signIns.isEmpty)

        // Get New Code starts a fresh request.
        viewModel.requestNewCode()
        await waitUntil(viewModel.phase == .waiting(code: "482917"))
        let initiations = await stub.initiateCalls
        XCTAssertEqual(initiations, 2)
        viewModel.cancel()
    }

    // MARK: - Cancelled

    func testCancelStopsPollingWithNoFurtherRequests() async throws {
        let stub = StubQuickConnect(answers: [.success(false)])
        let viewModel = model(stub)

        viewModel.start(serverURL: try XCTUnwrap(server))
        await waitUntil(viewModel.phase == .waiting(code: "482917"))
        // Let it poll a couple of times first (bounded, so a broken model
        // fails here instead of hanging).
        var polls = 0
        let deadline = ContinuousClock.now + .seconds(3)
        while polls < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
            polls = await stub.stateCalls
        }
        XCTAssertGreaterThanOrEqual(polls, 2, "polls while waiting")

        viewModel.cancel()
        let callsAtCancel = await stub.totalCalls
        try await Task.sleep(for: .milliseconds(150))  // ≈ 15 poll intervals
        let callsLater = await stub.totalCalls
        let signIns = await stub.signedInSecrets

        XCTAssertEqual(viewModel.phase, .idle)
        XCTAssertFalse(viewModel.isActive)
        XCTAssertEqual(callsLater, callsAtCancel, "a cancelled request makes no further requests")
        XCTAssertTrue(signIns.isEmpty)
    }

    func testCancelWhileAskingForACodeNeverPolls() async throws {
        let stub = StubQuickConnect()
        let viewModel = model(stub)

        viewModel.start(serverURL: try XCTUnwrap(server))
        viewModel.cancel()
        try await Task.sleep(for: .milliseconds(100))

        let polls = await stub.stateCalls
        XCTAssertEqual(polls, 0)
        XCTAssertEqual(viewModel.phase, .idle)
    }

    // MARK: - Disabled

    func testButtonIsHiddenWhenTheServerHasQuickConnectOff() async throws {
        let viewModel = model(StubQuickConnect(enabled: false))
        await viewModel.refreshAvailability(for: try XCTUnwrap(server))
        XCTAssertFalse(viewModel.isAvailable)
    }

    func testButtonIsShownWhenTheServerHasQuickConnectOn() async throws {
        let viewModel = model(StubQuickConnect(enabled: true))
        await viewModel.refreshAvailability(for: try XCTUnwrap(server))
        XCTAssertTrue(viewModel.isAvailable)
    }

    func testNoAddressHidesTheButtonWithoutAskingTheServer() async throws {
        let stub = StubQuickConnect(enabled: true)
        let viewModel = model(stub)
        await viewModel.refreshAvailability(for: try XCTUnwrap(server))
        await viewModel.refreshAvailability(for: nil)
        let asked = await stub.enabledCalls
        XCTAssertFalse(viewModel.isAvailable)
        XCTAssertEqual(asked, 1)
    }

    // MARK: - Failures

    func testABriefNetworkFailureKeepsPolling() async throws {
        let stub = StubQuickConnect(answers: [
            .failure(URLError(.networkConnectionLost)),
            .success(false),
            .success(true)
        ])
        let viewModel = model(stub)

        viewModel.start(serverURL: try XCTUnwrap(server))
        await waitUntil(viewModel.phase == .signedIn)
    }

    func testRepeatedFailuresGiveUpWithTryAgain() async throws {
        let stub = StubQuickConnect(answers: [.failure(URLError(.timedOut))])
        let viewModel = model(stub, failures: 3)

        viewModel.start(serverURL: try XCTUnwrap(server))
        await waitUntil({
            if case .failed = viewModel.phase { return true }
            return false
        }())
        let polls = await stub.stateCalls
        XCTAssertEqual(polls, 3)
    }

    func testAFailedSignInAfterApprovalIsReported() async throws {
        let stub = StubQuickConnect(answers: [.success(true)], signInError: JellyfinError.invalidCredentials)
        let viewModel = model(stub)

        viewModel.start(serverURL: try XCTUnwrap(server))
        await waitUntil({
            if case .failed = viewModel.phase { return true }
            return false
        }())
        let signIns = await stub.signedInSecrets
        XCTAssertEqual(signIns.count, 1, "not retried")
        if case .failed(let message) = viewModel.phase {
            XCTAssertFalse(message.contains("password"), "no password was involved: \(message)")
        }
    }

    // MARK: - Live service error mapping

    func testServerAnswersMapToQuickConnectErrors() {
        XCTAssertEqual(
            LiveQuickConnectService.translate(JellyfinError.httpError(statusCode: 404)) as? QuickConnectError,
            .expired
        )
        XCTAssertEqual(
            LiveQuickConnectService.translate(JellyfinError.invalidCredentials) as? QuickConnectError,
            .disabled
        )
        XCTAssertNil(LiveQuickConnectService.translate(URLError(.timedOut)) as? QuickConnectError)
    }
}
