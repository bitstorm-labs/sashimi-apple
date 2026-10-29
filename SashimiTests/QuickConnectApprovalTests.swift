import XCTest
@testable import Sashimi

private actor StubApprovalClient: QuickConnectApprovalClient {
    private let enabled: Bool
    private let answer: Result<Bool, Error>
    private(set) var authorizedCodes: [String] = []

    init(enabled: Bool = true, answer: Result<Bool, Error> = .success(true)) {
        self.enabled = enabled
        self.answer = answer
    }

    func isQuickConnectEnabled() async -> Bool { enabled }

    func authorizeQuickConnect(code: String) async throws -> Bool {
        authorizedCodes.append(code)
        return try answer.get()
    }
}

/// Settings › Sign In a TV (#801).
@MainActor
final class QuickConnectApprovalTests: XCTestCase {
    func testRowIsHiddenWhenQuickConnectIsOff() async {
        let model = QuickConnectApprovalViewModel(client: StubApprovalClient(enabled: false))
        await model.refreshAvailability()
        XCTAssertFalse(model.isAvailable)
    }

    func testRowIsShownWhenQuickConnectIsOn() async {
        let model = QuickConnectApprovalViewModel(client: StubApprovalClient(enabled: true))
        await model.refreshAvailability()
        XCTAssertTrue(model.isAvailable)
    }

    func testApproveIsEnabledOnlyWithAllSixDigits() {
        let model = QuickConnectApprovalViewModel(client: StubApprovalClient())
        XCTAssertFalse(model.canApprove)
        model.code = "48291"
        XCTAssertFalse(model.canApprove)
        model.code = "482917"
        XCTAssertTrue(model.canApprove)
    }

    func testCodeKeepsDigitsOnlyAndAtMostSix() {
        let model = QuickConnectApprovalViewModel(client: StubApprovalClient())
        model.code = "48 29-17 99"
        XCTAssertEqual(model.code, "482917")
        model.code = "abc"
        XCTAssertEqual(model.code, "")
    }

    func testApprovingSendsTheCodeAndReportsTVSignedIn() async {
        let client = StubApprovalClient(answer: .success(true))
        let model = QuickConnectApprovalViewModel(client: client)
        model.code = "482917"

        await model.approve()

        let codes = await client.authorizedCodes
        XCTAssertEqual(codes, ["482917"])
        XCTAssertEqual(model.phase, .approved)
    }

    func testAnUnknownOrExpiredCodeSaysSo() async {
        let model = QuickConnectApprovalViewModel(
            client: StubApprovalClient(answer: .failure(JellyfinError.httpError(statusCode: 404)))
        )
        model.code = "000000"

        await model.approve()

        XCTAssertEqual(model.phase, .failed("Code not found or expired"))
    }

    func testAnIncompleteCodeIsNeverSent() async {
        let client = StubApprovalClient()
        let model = QuickConnectApprovalViewModel(client: client)
        model.code = "4829"

        await model.approve()

        let codes = await client.authorizedCodes
        XCTAssertTrue(codes.isEmpty)
        XCTAssertEqual(model.phase, .entering)
    }

    func testEditingTheCodeClearsTheLastResult() async {
        let model = QuickConnectApprovalViewModel(
            client: StubApprovalClient(answer: .failure(JellyfinError.httpError(statusCode: 404)))
        )
        model.code = "000000"
        await model.approve()
        model.code = "00000"
        XCTAssertEqual(model.phase, .entering)
    }
}
