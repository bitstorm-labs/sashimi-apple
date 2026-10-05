import XCTest
@testable import SashimiMobile

/// The queue decisions behind "downloads keep going while the device
/// sleeps" (#613).
final class DownloadQueuePolicyTests: XCTestCase {
    private static let plentyOfSpace: Int64 = 50 * 1024 * 1024 * 1024

    private static func urlError(_ code: Int, userInfo: [String: Any] = [:]) -> NSError {
        NSError(domain: NSURLErrorDomain, code: code, userInfo: userInfo)
    }

    private static func cancelled(reason: Int) -> NSError {
        urlError(NSURLErrorCancelled, userInfo: [NSURLErrorBackgroundTaskCancelledReasonKey: reason])
    }

    // MARK: - Hand-off: every queued download gets its task at once

    func testQueuedDownloadsAreAllHandedOverWithoutWaitingForEachOther() {
        let steps = DownloadHandOff.plan(
            Array(repeating: (quality: DownloadQuality.low, originalVerified: false), count: 3),
            freeBytes: Self.plentyOfSpace
        )
        XCTAssertEqual(steps, [.handOver, .handOver, .handOver])
    }

    func testUncheckedOriginalAsksTheServerFirstButDoesNotHoldUpTheRest() {
        let steps = DownloadHandOff.plan(
            [(.original, false), (.medium, false), (.original, true)],
            freeBytes: Self.plentyOfSpace
        )
        XCTAssertEqual(steps, [.checkOriginal, .handOver, .handOver])
    }

    func testLowDiskSpaceFailsInsteadOfHandingOver() {
        guard case .fail(let message) = DownloadHandOff.step(quality: .low, originalVerified: false, freeBytes: 1024) else {
            return XCTFail("expected a failure")
        }
        XCTAssertTrue(message.hasPrefix("Not enough disk space"))
    }

    func testOriginalCheckWaitsForTheNetworkInsteadOfFallingBackToHigh() {
        let offline = DownloadHandOff.originalCheckOutcome(.failure(Self.urlError(NSURLErrorNotConnectedToInternet)))
        XCTAssertEqual(offline, .waitForNetwork)
        XCTAssertEqual(DownloadHandOff.originalCheckOutcome(.success(true)), .quality(.original))
        XCTAssertEqual(DownloadHandOff.originalCheckOutcome(.success(false)), .quality(.high))
        // Not a network problem: keep the old fail-closed answer.
        XCTAssertEqual(DownloadHandOff.originalCheckOutcome(.failure(JellyfinError.httpError(statusCode: 404))), .quality(.high))
    }

    /// A retry (manual, automatic, or the relaunch requeue) rebuilds the
    /// request from the stored record. Offline, nothing on that path may
    /// fail the download: it stays Queued until the network is back.
    func testRetryWithNoNetworkLeavesTheDownloadQueued() {
        let offline = Self.urlError(NSURLErrorNotConnectedToInternet)
        for quality in DownloadQuality.allCases {
            switch DownloadHandOff.step(quality: quality, originalVerified: false, freeBytes: Self.plentyOfSpace) {
            case .handOver:
                break // The background task waits for connectivity itself.
            case .checkOriginal:
                XCTAssertEqual(DownloadHandOff.originalCheckOutcome(.failure(offline)), .waitForNetwork)
            case .fail(let message):
                XCTFail("\(quality) retry failed offline: \(message)")
            }
        }
    }

    // MARK: - Task errors: sleep, suspension and outages are not failures

    func testSystemCancellationsOfBackgroundTasksRequeue() {
        let reasons = [
            NSURLErrorCancelledReasonUserForceQuitApplication,
            NSURLErrorCancelledReasonBackgroundUpdatesDisabled,
            NSURLErrorCancelledReasonInsufficientSystemResources
        ]
        for reason in reasons {
            XCTAssertEqual(
                DownloadTaskEnd.resolve(error: Self.cancelled(reason: reason), appIsActive: false, networkAllowsDownloads: true),
                .requeue,
                "reason \(reason)"
            )
        }
    }

    func testTheAppsOwnCancelIsIgnored() {
        XCTAssertEqual(
            DownloadTaskEnd.resolve(error: Self.urlError(NSURLErrorCancelled), appIsActive: true, networkAllowsDownloads: true),
            .ignore
        )
    }

    func testNetworkLossRequeuesEvenInTheForeground() {
        let codes = [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
            NSURLErrorBackgroundSessionWasDisconnected
        ]
        for code in codes {
            XCTAssertEqual(
                DownloadTaskEnd.resolve(error: Self.urlError(code), appIsActive: true, networkAllowsDownloads: true),
                .requeue,
                "code \(code)"
            )
        }
    }

    func testTimeoutsRequeueWhileBackgroundedButCountInTheForeground() {
        let timedOut = Self.urlError(NSURLErrorTimedOut)
        XCTAssertEqual(DownloadTaskEnd.resolve(error: timedOut, appIsActive: false, networkAllowsDownloads: true), .requeue)
        XCTAssertEqual(
            DownloadTaskEnd.resolve(error: timedOut, appIsActive: true, networkAllowsDownloads: true),
            .fail(.transient)
        )
    }

    func testAnyTransientErrorDuringAnOutageRequeues() {
        let serverError = JellyfinError.httpError(statusCode: 503)
        XCTAssertEqual(DownloadTaskEnd.resolve(error: serverError, appIsActive: true, networkAllowsDownloads: false), .requeue)
        XCTAssertEqual(
            DownloadTaskEnd.resolve(error: serverError, appIsActive: true, networkAllowsDownloads: true),
            .fail(.transient)
        )
    }

    func testPermanentErrorsStillFail() {
        let untrusted = Self.urlError(NSURLErrorServerCertificateUntrusted)
        XCTAssertEqual(
            DownloadTaskEnd.resolve(error: untrusted, appIsActive: false, networkAllowsDownloads: false),
            .fail(.permanent)
        )
    }

    // MARK: - Queued vs running

    private func entry(_ id: String, task: Int, bytes: Int64 = 0, host: String = "a") -> DownloadTaskSchedule.Entry {
        DownloadTaskSchedule.Entry(recordID: id, host: host, taskIdentifier: task, bytesReceived: bytes)
    }

    func testTasksBeyondTheLimitShowAsQueued() {
        let slots = DownloadTaskSchedule.slots(
            [entry("c", task: 3), entry("a", task: 1, bytes: 500), entry("b", task: 2), entry("d", task: 4)],
            limit: 2
        )
        XCTAssertEqual(slots, ["a": .downloading, "b": .preparing, "c": .queued, "d": .queued])
    }

    func testTheLimitIsPerServer() {
        let slots = DownloadTaskSchedule.slots(
            [entry("a", task: 1), entry("b", task: 2), entry("x", task: 3, host: "b")],
            limit: 1
        )
        XCTAssertEqual(slots, ["a": .preparing, "b": .queued, "x": .preparing])
    }

    // MARK: - Relaunch reconciliation

    private typealias Reconciler = DownloadRelaunchReconciler

    private func record(
        _ id: String,
        _ status: DownloadStatus,
        message: String? = nil,
        retryEntry: Bool = false
    ) -> Reconciler.Record {
        Reconciler.Record(recordID: id, status: status, errorMessage: message, hasRetryEntry: retryEntry)
    }

    private func task(_ id: Int, _ recordID: String?, bytes: Int64 = 0, live: Bool = true) -> Reconciler.SessionTask {
        Reconciler.SessionTask(taskIdentifier: id, recordID: recordID, isLive: live, bytesReceived: bytes)
    }

    func testRelaunchAdoptsLiveTasksAndRequeuesUnfinishedDownloadsWithoutOne() {
        let plan = Reconciler.plan(
            records: [
                record("running", .downloading),
                record("waiting", .queued),
                record("interrupted", .downloading),
                record("done", .completed)
            ],
            tasks: [task(7, "running", bytes: 1_000), task(8, "waiting")],
            alreadyRecovered: []
        )
        XCTAssertEqual(plan.adopt, ["running": 7, "waiting": 8])
        // Interrupted while the app was gone: queued again, not failed.
        XCTAssertEqual(plan.requeue, ["interrupted"])
        XCTAssertEqual(plan.cancel, [])
    }

    func testRelaunchNeverRunsADownloadTwice() {
        let plan = Reconciler.plan(
            records: [record("a", .downloading), record("gone", .completed)],
            tasks: [task(1, "a"), task(2, "a", bytes: 4_096), task(3, "gone"), task(4, nil), task(5, "a", live: false)],
            alreadyRecovered: []
        )
        XCTAssertEqual(plan.adopt, ["a": 2])
        XCTAssertEqual(plan.cancel, [1, 3, 4])
        XCTAssertEqual(plan.requeue, [])
    }

    func testFailuresCausedBySleepAreRecoveredOnce() {
        let records = [
            record("fetch", .failed, message: "Could not fetch item info"),
            record("interrupted", .failed, message: "Download interrupted. Tap retry to restart."),
            record("transient", .failed, message: "The request timed out.", retryEntry: true),
            record("forbidden", .failed, message: "Server returned HTTP 403")
        ]
        let first = Reconciler.plan(records: records, tasks: [], alreadyRecovered: [])
        XCTAssertEqual(first.recover, ["fetch", "interrupted", "transient"])

        let second = Reconciler.plan(records: records, tasks: [], alreadyRecovered: Set(first.recover))
        XCTAssertEqual(second.recover, [])
    }
}
