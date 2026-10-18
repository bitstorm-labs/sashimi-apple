import Foundation
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "RemoteControl")

extension Notification.Name {
    /// The server asked this device to stop playback (Playstate `Stop`). Any
    /// presented player closes exactly as if the viewer had pressed Back.
    static let remotePlaybackStopRequested = Notification.Name("remotePlaybackStopRequested")
}

/// Something that holds a remote-control connection open between `start` and
/// `stop`.
@MainActor
protocol RemoteControlConnection: AnyObject {
    func start()
    func stop()
}

extension RemoteControlSession: RemoteControlConnection {}

/// Decides when the remote-control socket should be open: signed in and in
/// the foreground, one connection per active server session (#723).
///
/// Backgrounding closes it (iOS would suspend it anyway, and a dead socket
/// left registered makes the dashboard offer buttons that go nowhere);
/// returning to the foreground, switching servers or re-signing in opens a
/// fresh one straight away rather than waiting out a reconnect backoff.
@MainActor
final class RemoteControlCoordinator {
    static let shared = RemoteControlCoordinator(makeConnection: RemoteControlCoordinator.liveConnection)

    private let makeConnection: @MainActor () -> any RemoteControlConnection
    private var connection: (any RemoteControlConnection)?
    /// The session identity the open connection belongs to.
    private var connectedIdentity: String?
    private var isAuthenticated = false
    private var identity = ""
    private var isForeground = false

    init(makeConnection: @escaping @MainActor () -> any RemoteControlConnection) {
        self.makeConnection = makeConnection
    }

    var isConnected: Bool { connection != nil }

    func update(isAuthenticated: Bool, identity: String, isForeground: Bool) {
        self.isAuthenticated = isAuthenticated
        self.identity = identity
        self.isForeground = isForeground
        apply()
    }

    func setForeground(_ isForeground: Bool) {
        self.isForeground = isForeground
        apply()
    }

    func setSession(isAuthenticated: Bool, identity: String) {
        self.isAuthenticated = isAuthenticated
        self.identity = identity
        apply()
    }

    /// The network came back: a socket from before the outage is almost
    /// certainly dead, and its backoff may be long. Start over.
    func networkDidReconnect() {
        guard connection != nil else { return }
        disconnect()
        apply()
    }

    private func apply() {
        let wanted = isAuthenticated && isForeground ? identity : nil
        guard wanted != connectedIdentity else { return }
        disconnect()
        guard let wanted else { return }
        let connection = makeConnection()
        self.connection = connection
        connectedIdentity = wanted
        connection.start()
    }

    private func disconnect() {
        connection?.stop()
        connection = nil
        connectedIdentity = nil
    }

    // MARK: - Production wiring

    static func liveConnection() -> any RemoteControlConnection {
        RemoteControlSession(
            connect: {
                let client = JellyfinClient.shared
                guard let request = await client.remoteControlSocketRequest() else {
                    throw JellyfinError.notConfigured
                }
                return URLSessionRemoteControlTransport(task: await client.makeRemoteControlSocket(request))
            },
            registerCapabilities: {
                do {
                    try await JellyfinClient.shared.registerRemoteControlCapabilities()
                } catch {
                    logger.error("Registering remote-control capabilities failed: \(error.localizedDescription, privacy: .public)")
                }
            },
            onCommand: { command in
                switch command {
                case .stop:
                    logger.info("Remote Stop received")
                    NotificationCenter.default.post(name: .remotePlaybackStopRequested, object: nil)
                case .displayMessage(let message):
                    logger.info("Remote message received")
                    RemoteMessagePresenter.shared.show(message)
                }
            }
        )
    }
}

/// `URLSessionWebSocketTask` as a `RemoteControlTransport`. The task is
/// thread-safe; it is only resumed here and cancelled in `close`.
final class URLSessionRemoteControlTransport: RemoteControlTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
        task.resume()
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(bytes: data, encoding: .utf8) ?? ""
        @unknown default:
            return ""
        }
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func close() {
        task.cancel(with: .goingAway, reason: nil)
    }
}
