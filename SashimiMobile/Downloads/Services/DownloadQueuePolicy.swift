import Foundation

// The decisions behind the download queue, kept free of URLSession and
// SwiftData so they can be tested directly. DownloadManager applies them.
//
// Every queued download is handed to the background URLSession as soon as it
// is queued, while the app is in the foreground. nsurlsessiond then runs them
// `DownloadQueuePolicy.maxConcurrentDownloads` at a time (the session's
// httpMaximumConnectionsPerHost) whether or not the app is running. The app
// used to keep the queue itself and start each download only after the
// previous one finished, which happened only while iOS had the app awake: a
// sleeping iPad finished one download, then waited for the app to be opened.

enum DownloadQueuePolicy {
    /// Downloads that run at once against one server. Each transcoded
    /// download is a live ffmpeg (QSV) process on the server, so this is
    /// also how many transcodes one device can hold open. Two keeps the
    /// server's load bounded while hiding ffmpeg's start-up behind the other
    /// download, and one stalled transcode no longer holds up the rest of the
    /// queue. (It is a per-connection limit: a server reached over HTTP/2 can
    /// multiplex more than this onto one connection.)
    static let maxConcurrentDownloads = 2

    /// Below this, a download is refused rather than started.
    static let minimumFreeBytes: Int64 = 500 * 1024 * 1024
}

// MARK: - Handing a download to the session

/// What to do with a queued download that has no task yet.
enum DownloadHandOffStep: Equatable {
    /// Build its request and create the background task now. No network.
    case handOver
    /// "Original" asks the server whether the source plays on this device
    /// first (PlaybackInfo), then hands over at the quality that implies.
    case checkOriginal
    case fail(String)
}

/// The result of the Original compatibility check.
enum DownloadOriginalCheckOutcome: Equatable {
    case quality(DownloadQuality)
    /// The server couldn't be asked (offline, asleep, server unreachable):
    /// stay queued and ask again later, rather than fall back to High.
    case waitForNetwork
}

enum DownloadHandOff {
    static func step(quality: DownloadQuality, originalVerified: Bool, freeBytes: Int64) -> DownloadHandOffStep {
        guard freeBytes >= DownloadQueuePolicy.minimumFreeBytes else {
            let available = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
            return .fail("Not enough disk space. Available: \(available)")
        }
        return quality == .original && !originalVerified ? .checkOriginal : .handOver
    }

    /// Each queued download's step, decided on its own: none waits for
    /// another to finish downloading first.
    static func plan(
        _ jobs: [(quality: DownloadQuality, originalVerified: Bool)],
        freeBytes: Int64
    ) -> [DownloadHandOffStep] {
        jobs.map { step(quality: $0.quality, originalVerified: $0.originalVerified, freeBytes: freeBytes) }
    }

    /// `compatible` is the check's answer, or the error that prevented one.
    /// A transient error (no network, timeout, server hiccup) waits; any
    /// other failure keeps the old fail-closed answer, High.
    static func originalCheckOutcome(_ compatible: Result<Bool, Error>) -> DownloadOriginalCheckOutcome {
        switch compatible {
        case .success(let isCompatible):
            return .quality(DownloadQuality.effectiveQuality(requested: .original, sourceIsCompatible: isCompatible))
        case .failure(let error):
            return DownloadRetryPolicy.classify(error: error) == .transient ? .waitForNetwork : .quality(.high)
        }
    }
}

// MARK: - A task that ended with an error

/// What a background task's error means for its download.
enum DownloadTaskEnd: Equatable {
    /// The app cancelled it (cancel, delete, restart): already handled.
    case ignore
    /// The device slept, the app was suspended or killed, or the network
    /// went away. Not the download's fault: back to Queued, no retry attempt
    /// used, and it starts again by itself (from zero for a transcode -- the
    /// server sends no byte ranges to resume from).
    case requeue
    case fail(DownloadFailureKind)

    /// Errors that only mean the network or the system interrupted the task.
    static let interruptionCodes: Set<Int> = [
        NSURLErrorNotConnectedToInternet,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorBackgroundSessionWasDisconnected,
        NSURLErrorDataNotAllowed,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive
    ]

    /// Errors that are an interruption when the app wasn't in the foreground
    /// (a woken device whose Wi-Fi isn't back yet), but a real failure to
    /// count while the user is watching.
    static let backgroundInterruptionCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotConnectToHost,
        NSURLErrorCannotFindHost,
        NSURLErrorDNSLookupFailed
    ]

    static func resolve(error: Error, appIsActive: Bool, networkAllowsDownloads: Bool) -> DownloadTaskEnd {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if nsError.code == NSURLErrorCancelled {
                // The system cancels background tasks with a reason (force
                // quit, Background App Refresh off, low resources); the app's
                // own cancels carry none.
                return nsError.userInfo[NSURLErrorBackgroundTaskCancelledReasonKey] == nil ? .ignore : .requeue
            }
            if interruptionCodes.contains(nsError.code) { return .requeue }
            if !appIsActive && backgroundInterruptionCodes.contains(nsError.code) { return .requeue }
        }
        let kind = DownloadRetryPolicy.classify(error: error)
        // Whatever it was, it happened while downloads couldn't use the
        // network: the outage, not the download, is what failed.
        if kind == .transient && !networkAllowsDownloads { return .requeue }
        return .fail(kind)
    }
}

// MARK: - Queued vs running

/// Where a download handed to the session stands.
enum DownloadTaskSlot: Equatable {
    /// Waiting behind the concurrency limit.
    case queued
    /// Has a connection; the server hasn't sent anything yet (ffmpeg starting).
    case preparing
    case downloading
}

/// The session doesn't say which of its tasks hold a connection, so this
/// infers it: a task that has received bytes is downloading, and the rest of
/// each server's slots go to its oldest tasks (the session starts them in
/// the order they were created). Everything else is queued.
enum DownloadTaskSchedule {
    struct Entry: Equatable {
        let recordID: String
        /// Server host and port: the limit is per host.
        let host: String
        /// Increases with creation order within a session.
        let taskIdentifier: Int
        let bytesReceived: Int64
    }

    static func slots(_ entries: [Entry], limit: Int = DownloadQueuePolicy.maxConcurrentDownloads) -> [String: DownloadTaskSlot] {
        var result: [String: DownloadTaskSlot] = [:]
        for hostEntries in Dictionary(grouping: entries, by: \.host).values {
            let started = hostEntries.filter { $0.bytesReceived > 0 }
            started.forEach { result[$0.recordID] = .downloading }
            var free = max(limit - started.count, 0)
            for entry in hostEntries.filter({ $0.bytesReceived <= 0 }).sorted(by: { $0.taskIdentifier < $1.taskIdentifier }) {
                if free > 0 {
                    result[entry.recordID] = .preparing
                    free -= 1
                } else {
                    result[entry.recordID] = .queued
                }
            }
        }
        return result
    }
}

// MARK: - Relaunch

/// After a relaunch: matches the tasks the session still holds against the
/// download records, so nothing is downloaded twice and nothing is dropped.
enum DownloadRelaunchReconciler {
    struct Record: Equatable {
        let recordID: String
        let status: DownloadStatus
        let errorMessage: String?
        /// A transient failure has an automatic-retry entry.
        let hasRetryEntry: Bool
    }

    struct SessionTask: Equatable {
        let taskIdentifier: Int
        /// From the persisted task map; nil for a task the app can't place.
        let recordID: String?
        /// Running or suspended (not completed or cancelling).
        let isLive: Bool
        let bytesReceived: Int64
    }

    struct Plan: Equatable {
        /// Tasks to keep tracking, by record.
        var adopt: [String: Int] = [:]
        /// Tasks with no download to belong to, or a second task for one.
        var cancel: [Int] = []
        /// Unfinished downloads with no task: hand them to the session again.
        var requeue: [String] = []
        /// Failed downloads that only failed because the device slept or the
        /// network dropped (under earlier builds): queued again, once.
        var recover: [String] = []
    }

    /// What earlier builds wrote on a download that failed only because the
    /// app was asleep, offline or killed.
    static let interruptionMessages: Set<String> = [
        "Could not fetch item info",
        "Download interrupted. Tap retry to restart."
    ]

    static func plan(records: [Record], tasks: [SessionTask], alreadyRecovered: Set<String>) -> Plan {
        var plan = Plan()
        let recordsByID = Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })

        var liveByRecord: [String: [SessionTask]] = [:]
        for task in tasks where task.isLive {
            guard let recordID = task.recordID,
                  let record = recordsByID[recordID],
                  isUnfinished(record.status) else {
                plan.cancel.append(task.taskIdentifier)
                continue
            }
            liveByRecord[recordID, default: []].append(task)
        }
        for (recordID, candidates) in liveByRecord {
            // Keep the one furthest along; the oldest on a tie.
            let ordered = candidates.sorted {
                $0.bytesReceived != $1.bytesReceived
                    ? $0.bytesReceived > $1.bytesReceived
                    : $0.taskIdentifier < $1.taskIdentifier
            }
            plan.adopt[recordID] = ordered[0].taskIdentifier
            plan.cancel.append(contentsOf: ordered.dropFirst().map(\.taskIdentifier))
        }

        for record in records {
            if isUnfinished(record.status) {
                if plan.adopt[record.recordID] == nil { plan.requeue.append(record.recordID) }
            } else if record.status == .failed,
                      !alreadyRecovered.contains(record.recordID),
                      record.hasRetryEntry || interruptionMessages.contains(record.errorMessage ?? "") {
                plan.recover.append(record.recordID)
            }
        }
        plan.cancel.sort()
        return plan
    }

    private static func isUnfinished(_ status: DownloadStatus) -> Bool {
        status == .queued || status == .preparing || status == .downloading
    }
}
