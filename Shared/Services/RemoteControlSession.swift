import Foundation
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "RemoteControl")

/// A text WebSocket. `URLSessionWebSocketTask` in production, a script in tests.
protocol RemoteControlTransport: AnyObject, Sendable {
    func receive() async throws -> String
    func send(_ text: String) async throws
    func close()
}

/// Keeps one Jellyfin `/socket` connection alive and turns its frames into
/// commands.
///
/// Jellyfin only reports a session as remote-controllable while it has BOTH
/// posted `SupportsMediaControl` capabilities and holds an open socket, so the
/// capabilities are (re)posted on every connection, once the server has spoken
/// on it (proof the socket is really open, not merely resumed).
///
/// Reconnects back off exponentially. The backoff only resets when a
/// connection has carried a frame: a server that accepts and immediately drops
/// the socket (an auth rejection, a proxy without WebSocket support) keeps
/// backing off instead of reconnecting every second forever.
@MainActor
final class RemoteControlSession {
    typealias Connect = @MainActor () async throws -> any RemoteControlTransport
    typealias Sleep = @MainActor (TimeInterval) async throws -> Void

    private let connect: Connect
    private let registerCapabilities: @MainActor () async -> Void
    private let policy: RemoteControlReconnectPolicy
    private let reconnectSleep: Sleep
    private let keepAliveSleep: Sleep
    private let onCommand: @MainActor (RemoteControlCommand) -> Void

    private var runTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var transport: (any RemoteControlTransport)?
    /// Bumped on every start/stop so a loop that outlives its stop can tell.
    private var generation = 0

    var isRunning: Bool { runTask != nil }

    static let realSleep: Sleep = { seconds in
        try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    }

    init(
        connect: @escaping Connect,
        registerCapabilities: @escaping @MainActor () async -> Void,
        policy: RemoteControlReconnectPolicy = RemoteControlReconnectPolicy(),
        reconnectSleep: @escaping Sleep = RemoteControlSession.realSleep,
        keepAliveSleep: @escaping Sleep = RemoteControlSession.realSleep,
        onCommand: @escaping @MainActor (RemoteControlCommand) -> Void
    ) {
        self.connect = connect
        self.registerCapabilities = registerCapabilities
        self.policy = policy
        self.reconnectSleep = reconnectSleep
        self.keepAliveSleep = keepAliveSleep
        self.onCommand = onCommand
    }

    /// Connects now (no backoff) unless already running.
    func start() {
        guard runTask == nil else { return }
        generation += 1
        let generation = generation
        runTask = Task { [weak self] in
            await self?.run(generation: generation)
        }
    }

    /// Closes the socket; no reconnect follows.
    func stop() {
        generation += 1
        runTask?.cancel()
        runTask = nil
        endConnection()
    }

    private func run(generation: Int) async {
        var failures = 0
        while !Task.isCancelled, generation == self.generation {
            var spoke = false
            do {
                let transport = try await connect()
                guard !Task.isCancelled, generation == self.generation else {
                    transport.close()
                    return
                }
                self.transport = transport
                try await receiveLoop(transport, generation: generation, spoke: &spoke)
            } catch {
                if !Task.isCancelled {
                    logger.info("Remote control socket ended: \(error.localizedDescription, privacy: .public)")
                }
            }
            // A stopped loop must not touch the connection: `stop()` already
            // closed it, and after a restart it belongs to the new loop.
            guard !Task.isCancelled, generation == self.generation else { return }
            endConnection()

            failures = spoke ? 0 : failures + 1
            do {
                try await reconnectSleep(policy.delay(forAttempt: max(failures - 1, 0)))
            } catch {
                return
            }
        }
    }

    private func receiveLoop(
        _ transport: any RemoteControlTransport,
        generation: Int,
        spoke: inout Bool
    ) async throws {
        while true {
            let frame = try await transport.receive()
            guard !Task.isCancelled, generation == self.generation else { throw CancellationError() }
            if !spoke {
                spoke = true
                Task { await registerCapabilities() }
            }
            switch RemoteControlMessage.parse(frame) {
            case .forceKeepAlive(let seconds):
                startKeepAlive(transport, every: RemoteControlMessage.keepAliveInterval(forTimeout: seconds))
            case .command(let command):
                onCommand(command)
            case .keepAlive, .ignored:
                break
            }
        }
    }

    private func startKeepAlive(_ transport: any RemoteControlTransport, every interval: TimeInterval) {
        keepAliveTask?.cancel()
        let sleep = keepAliveSleep
        keepAliveTask = Task {
            while !Task.isCancelled {
                do {
                    try await transport.send(RemoteControlMessage.keepAliveFrame)
                    try await sleep(interval)
                } catch {
                    return
                }
            }
        }
    }

    private func endConnection() {
        keepAliveTask?.cancel()
        keepAliveTask = nil
        transport?.close()
        transport = nil
    }
}
