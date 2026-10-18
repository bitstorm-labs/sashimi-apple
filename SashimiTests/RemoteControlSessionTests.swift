import XCTest
@testable import Sashimi

/// A socket the test speaks for the server through.
private final class FakeTransport: RemoteControlTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var iterator: AsyncThrowingStream<String, Error>.AsyncIterator
    private let continuation: AsyncThrowingStream<String, Error>.Continuation
    private var sentFrames: [String] = []
    private var isClosed = false

    init() {
        var continuation: AsyncThrowingStream<String, Error>.Continuation?
        let stream = AsyncThrowingStream<String, Error> { continuation = $0 }
        self.iterator = stream.makeAsyncIterator()
        // swiftlint:disable:next force_unwrapping
        self.continuation = continuation!
    }

    var sent: [String] { lock.withLock { sentFrames } }
    var closed: Bool { lock.withLock { isClosed } }

    func serverSends(_ frame: String) { continuation.yield(frame) }
    func serverDrops() { continuation.finish(throwing: URLError(.networkConnectionLost)) }

    func receive() async throws -> String {
        var iterator = lock.withLock { self.iterator }
        guard let frame = try await iterator.next() else { throw URLError(.networkConnectionLost) }
        lock.withLock { self.iterator = iterator }
        return frame
    }

    func send(_ text: String) async throws {
        lock.withLock { sentFrames.append(text) }
    }

    func close() {
        lock.withLock { isClosed = true }
        continuation.finish()
    }
}

private let forceKeepAlive = #"{"MessageId":"1","Data":60,"MessageType":"ForceKeepAlive"}"#
private let stopFrame = #"{"MessageId":"2","Data":{"Command":"Stop"},"MessageType":"Playstate"}"#
private let messageFrame = #"{"Data":{"Name":"DisplayMessage","Arguments":{"Header":"H","Text":"T","TimeoutMs":"3000"}},"MessageType":"GeneralCommand"}"#

/// Drives `RemoteControlSession` with scripted connections and a clock that
/// never really waits.
@MainActor
final class RemoteControlSessionTests: XCTestCase {
    private enum Outcome {
        case fail
        case transport(FakeTransport)
    }

    private var outcomes: [Outcome] = []
    private var connectCount = 0
    private var registrations = 0
    private var reconnectDelays: [TimeInterval] = []
    private var keepAliveDelays: [TimeInterval] = []
    private var commands: [RemoteControlCommand] = []
    private var onConnect: ((Int) -> Void)?
    private var onCommand: ((RemoteControlCommand) -> Void)?

    override func setUp() {
        super.setUp()
        outcomes = []
        connectCount = 0
        registrations = 0
        reconnectDelays = []
        keepAliveDelays = []
        commands = []
        onConnect = nil
        onCommand = nil
    }

    private func makeSession() -> RemoteControlSession {
        RemoteControlSession(
            connect: { [unowned self] in
                connectCount += 1
                onConnect?(connectCount)
                guard !outcomes.isEmpty else {
                    // Nothing scripted: a server that never answers.
                    try await Task.sleep(nanoseconds: 3_600 * NSEC_PER_SEC)
                    throw CancellationError()
                }
                switch outcomes.removeFirst() {
                case .fail: throw URLError(.cannotConnectToHost)
                case .transport(let transport): return transport
                }
            },
            registerCapabilities: { [unowned self] in registrations += 1 },
            policy: RemoteControlReconnectPolicy(initialDelay: 1, maximumDelay: 30),
            reconnectSleep: { [unowned self] delay in
                reconnectDelays.append(delay)
                try Task.checkCancellation()
            },
            keepAliveSleep: { [unowned self] delay in
                keepAliveDelays.append(delay)
                // One keep-alive per test is plenty; park the loop.
                try await Task.sleep(nanoseconds: 3_600 * NSEC_PER_SEC)
            },
            onCommand: { [unowned self] command in
                commands.append(command)
                onCommand?(command)
            }
        )
    }

    private func waitForConnects(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let reached = expectation(description: "connect #\(count)")
        if connectCount >= count {
            reached.fulfill()
        } else {
            onConnect = { if $0 == count { reached.fulfill() } }
        }
        await fulfillment(of: [reached], timeout: 5)
        onConnect = nil
    }

    private func waitForCommand() async {
        let received = expectation(description: "command")
        onCommand = { _ in received.fulfill() }
        await fulfillment(of: [received], timeout: 5)
        onCommand = nil
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    // MARK: - Commands

    func testStopFromTheServerIsDispatched() async {
        let transport = FakeTransport()
        outcomes = [.transport(transport)]
        let session = makeSession()
        session.start()
        await waitForConnects(1)

        transport.serverSends(forceKeepAlive)
        transport.serverSends(stopFrame)
        await waitForCommand()

        XCTAssertEqual(commands, [.stop])
        session.stop()
    }

    func testDisplayMessageIsDispatched() async {
        let transport = FakeTransport()
        outcomes = [.transport(transport)]
        let session = makeSession()
        session.start()
        await waitForConnects(1)

        transport.serverSends(messageFrame)
        await waitForCommand()

        XCTAssertEqual(commands, [.displayMessage(RemoteMessage(header: "H", text: "T", timeoutMs: 3000))])
        session.stop()
    }

    func testIgnoredCommandsNeitherDispatchNorDisconnect() async {
        let transport = FakeTransport()
        outcomes = [.transport(transport)]
        let session = makeSession()
        session.start()
        await waitForConnects(1)

        transport.serverSends(#"{"Data":{"Name":"SetVolume","Arguments":{"Volume":"3"}},"MessageType":"GeneralCommand"}"#)
        transport.serverSends(#"{"Data":{"Command":"Pause"},"MessageType":"Playstate"}"#)
        transport.serverSends("garbage")
        transport.serverSends(stopFrame)
        await waitForCommand()

        XCTAssertEqual(commands, [.stop], "only the stop got through")
        XCTAssertEqual(connectCount, 1, "nothing ignored dropped the socket")
        XCTAssertTrue(reconnectDelays.isEmpty)
        session.stop()
    }

    // MARK: - Keep-alive

    func testForceKeepAliveIsAnsweredAndScheduledAtHalfTheTimeout() async {
        let transport = FakeTransport()
        outcomes = [.transport(transport)]
        let session = makeSession()
        session.start()
        await waitForConnects(1)

        transport.serverSends(forceKeepAlive)
        transport.serverSends(stopFrame)
        await waitForCommand()
        await settle()

        XCTAssertEqual(transport.sent.first, RemoteControlMessage.keepAliveFrame)
        XCTAssertEqual(keepAliveDelays, [30])
        session.stop()
    }

    // MARK: - Capabilities

    func testCapabilitiesAreRegisteredOncePerConnectionOnceTheServerSpeaks() async {
        let first = FakeTransport()
        let second = FakeTransport()
        outcomes = [.transport(first), .transport(second)]
        let session = makeSession()
        session.start()
        await waitForConnects(1)
        await settle()
        XCTAssertEqual(registrations, 0, "not before the socket is proven open")

        first.serverSends(forceKeepAlive)
        await settle()
        XCTAssertEqual(registrations, 1)
        first.serverSends(forceKeepAlive)
        await settle()
        XCTAssertEqual(registrations, 1, "once per connection, not per frame")

        first.serverDrops()
        await waitForConnects(2)
        second.serverSends(forceKeepAlive)
        await settle()
        XCTAssertEqual(registrations, 2, "a new socket is a new server session to describe")
        session.stop()
    }

    // MARK: - Reconnect

    func testFailuresBackOffAndASpeakingConnectionResetsTheBackoff() async {
        let good = FakeTransport()
        outcomes = [.fail, .fail, .fail, .transport(good)]
        let session = makeSession()
        session.start()
        await waitForConnects(4)
        XCTAssertEqual(reconnectDelays, [1, 2, 4])

        good.serverSends(forceKeepAlive)
        await settle()
        good.serverDrops()
        await waitForConnects(5)

        XCTAssertEqual(reconnectDelays, [1, 2, 4, 1], "the server answered, so start over")
        XCTAssertTrue(good.closed)
        session.stop()
    }

    func testAConnectionThatDropsBeforeSpeakingKeepsBackingOff() async {
        let first = FakeTransport()
        let second = FakeTransport()
        outcomes = [.transport(first), .transport(second)]
        let session = makeSession()
        session.start()
        await waitForConnects(1)
        first.serverDrops()
        await waitForConnects(2)
        second.serverDrops()
        await waitForConnects(3)

        XCTAssertEqual(reconnectDelays, [1, 2], "an accepted-then-dropped socket is still a failure")
        session.stop()
    }

    // MARK: - Stop / start (background / foreground)

    func testStopClosesTheSocketAndNeverReconnects() async {
        let transport = FakeTransport()
        outcomes = [.transport(transport)]
        let session = makeSession()
        session.start()
        await waitForConnects(1)
        transport.serverSends(forceKeepAlive)
        await settle()

        session.stop()
        await settle()

        XCTAssertTrue(transport.closed)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(connectCount, 1)
        XCTAssertTrue(reconnectDelays.isEmpty, "a deliberate stop is not a failure to retry")
    }

    func testStartAfterStopConnectsStraightAway() async {
        let first = FakeTransport()
        let second = FakeTransport()
        outcomes = [.transport(first), .transport(second)]
        let session = makeSession()
        session.start()
        await waitForConnects(1)
        session.stop()

        session.start()
        await waitForConnects(2)

        XCTAssertTrue(reconnectDelays.isEmpty, "coming back to the foreground does not wait out a backoff")
        XCTAssertTrue(session.isRunning)
        session.stop()
    }

    func testStartIsIdempotent() async {
        let transport = FakeTransport()
        outcomes = [.transport(transport)]
        let session = makeSession()
        session.start()
        await waitForConnects(1)
        session.start()
        await settle()

        XCTAssertEqual(connectCount, 1)
        session.stop()
    }
}
