import XCTest
@testable import Sashimi

@MainActor
private final class FakeConnection: RemoteControlConnection {
    private(set) var starts = 0
    private(set) var stops = 0
    var isOpen: Bool { starts > stops }
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

/// When the remote-control socket is open: signed in, in front, one per
/// server session.
@MainActor
final class RemoteControlCoordinatorTests: XCTestCase {
    private var made: [FakeConnection] = []

    private func coordinator() -> RemoteControlCoordinator {
        made = []
        return RemoteControlCoordinator { [unowned self] in
            let connection = FakeConnection()
            made.append(connection)
            return connection
        }
    }

    func testSignedInAndInFrontConnects() {
        let coordinator = coordinator()
        coordinator.update(isAuthenticated: true, identity: "s1:0", isForeground: true)
        XCTAssertEqual(made.count, 1)
        XCTAssertTrue(made[0].isOpen)
    }

    func testSignedOutOrInTheBackgroundDoesNot() {
        let coordinator = coordinator()
        coordinator.update(isAuthenticated: false, identity: "none:0", isForeground: true)
        coordinator.update(isAuthenticated: true, identity: "s1:0", isForeground: false)
        XCTAssertTrue(made.isEmpty)
        XCTAssertFalse(coordinator.isConnected)
    }

    func testBackgroundClosesAndForegroundReopensAFreshConnection() {
        let coordinator = coordinator()
        coordinator.update(isAuthenticated: true, identity: "s1:0", isForeground: true)
        coordinator.setForeground(false)
        XCTAssertFalse(made[0].isOpen)
        XCTAssertFalse(coordinator.isConnected)

        coordinator.setForeground(true)
        XCTAssertEqual(made.count, 2, "a fresh connection, not the backed-off one")
        XCTAssertTrue(made[1].isOpen)
    }

    func testSwitchingServersReplacesTheConnection() {
        let coordinator = coordinator()
        coordinator.update(isAuthenticated: true, identity: "s1:0", isForeground: true)
        coordinator.setSession(isAuthenticated: true, identity: "s2:0")
        XCTAssertFalse(made[0].isOpen)
        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(made[1].isOpen)
    }

    func testSignOutCloses() {
        let coordinator = coordinator()
        coordinator.update(isAuthenticated: true, identity: "s1:0", isForeground: true)
        coordinator.setSession(isAuthenticated: false, identity: "none:0")
        XCTAssertFalse(made[0].isOpen)
        XCTAssertEqual(made.count, 1)
    }

    func testRepeatedUpdatesKeepTheConnection() {
        let coordinator = coordinator()
        coordinator.update(isAuthenticated: true, identity: "s1:0", isForeground: true)
        coordinator.update(isAuthenticated: true, identity: "s1:0", isForeground: true)
        coordinator.setForeground(true)
        coordinator.setSession(isAuthenticated: true, identity: "s1:0")
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].stops, 0)
    }

    func testNetworkReturnRestartsAnOpenConnection() {
        let coordinator = coordinator()
        coordinator.update(isAuthenticated: true, identity: "s1:0", isForeground: true)
        coordinator.networkDidReconnect()
        XCTAssertFalse(made[0].isOpen)
        XCTAssertEqual(made.count, 2)
        XCTAssertTrue(made[1].isOpen)
    }

    func testNetworkReturnWhileDisconnectedDoesNothing() {
        let coordinator = coordinator()
        coordinator.update(isAuthenticated: true, identity: "s1:0", isForeground: false)
        coordinator.networkDidReconnect()
        XCTAssertTrue(made.isEmpty)
    }
}
