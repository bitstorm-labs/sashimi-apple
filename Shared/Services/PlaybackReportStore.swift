import Foundation
import os

/// The four server-side events that make up an online playback session.
///
/// The store deliberately contains only server/item identifiers and playback
/// state. It never persists access tokens, URLs, or any other credential-bearing
/// value.
enum PlaybackReportKind: String, Codable, Hashable, Sendable {
    case start
    case progress
    case stopped
    case completion
}

struct PendingPlaybackReport: Codable, Hashable, Identifiable, Sendable {
    var id: UUID
    let serverID: String
    let itemID: String
    let playSessionID: String?
    let kind: PlaybackReportKind
    var playMethod: String?
    var positionTicks: Int64
    var isPaused: Bool
    var createdAt: Date
    /// Completion is a two-request Jellyfin operation. Persisting the first
    /// phase prevents a retry from sending the stopped event again after it
    /// already succeeded but the mark-played request failed.
    var completionStoppedDelivered: Bool
    var completionMarkedPlayed: Bool

    init(
        id: UUID = UUID(),
        serverID: String,
        itemID: String,
        playSessionID: String?,
        kind: PlaybackReportKind,
        playMethod: String? = nil,
        positionTicks: Int64,
        isPaused: Bool = false,
        createdAt: Date = Date(),
        completionStoppedDelivered: Bool = false,
        completionMarkedPlayed: Bool = false
    ) {
        self.id = id
        self.serverID = serverID
        self.itemID = itemID
        self.playSessionID = playSessionID
        self.kind = kind
        self.playMethod = playMethod
        self.positionTicks = positionTicks
        self.isPaused = isPaused
        self.createdAt = createdAt
        self.completionStoppedDelivered = completionStoppedDelivered
        self.completionMarkedPlayed = completionMarkedPlayed
    }

    /// Events of one kind for one server-local item/session coalesce. This is
    /// what keeps a reconnect from replaying every five-second progress sample.
    var deduplicationKey: String {
        [serverID, itemID, playSessionID ?? "", kind.rawValue].joined(separator: "|")
    }
}

@MainActor
final class PlaybackReportStore {
    static let shared = PlaybackReportStore()

    private static let storageKey = "pendingPlaybackReports.v1"
    private let defaults: UserDefaults
    private(set) var reports: [PendingPlaybackReport]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([PendingPlaybackReport].self, from: data) {
            reports = decoded.sorted { $0.createdAt < $1.createdAt }
        } else {
            reports = []
        }
    }

    /// Adds a report or replaces the older sample for the same logical event.
    /// Completion phase flags are preserved when a duplicate completion is
    /// received from a repeated end callback.
    @discardableResult
    func enqueue(_ report: PendingPlaybackReport) -> PendingPlaybackReport {
        var stored = report
        if let index = reports.firstIndex(where: { $0.deduplicationKey == report.deduplicationKey }) {
            let existing = reports[index]
            stored.id = existing.id
            stored.completionStoppedDelivered = existing.completionStoppedDelivered
            stored.completionMarkedPlayed = existing.completionMarkedPlayed
            reports[index] = stored
        } else {
            reports.append(stored)
        }
        reports.sort { $0.createdAt < $1.createdAt }
        persist()
        return stored
    }

    func update(_ report: PendingPlaybackReport) {
        guard let index = reports.firstIndex(where: { $0.id == report.id }) else { return }
        reports[index] = report
        reports.sort { $0.createdAt < $1.createdAt }
        persist()
    }

    func remove(id: UUID) {
        reports.removeAll { $0.id == id }
        persist()
    }

    /// Removes a report only if it is still the snapshot that was delivered.
    /// A newer progress sample may reuse the same UUID while the older
    /// request is suspended on the network.
    func remove(_ report: PendingPlaybackReport) {
        guard reports.first(where: { $0.id == report.id }) == report else { return }
        remove(id: report.id)
    }

    /// Completion delivery can be suspended between Jellyfin's stopped and
    /// mark-played requests. Merge each successful phase into the current
    /// snapshot so a newer duplicate cannot be overwritten by an older one.
    func markCompletionPhase(
        id: UUID,
        stoppedDelivered: Bool = false,
        markedPlayed: Bool = false
    ) {
        guard let index = reports.firstIndex(where: { $0.id == id }) else { return }
        if stoppedDelivered {
            reports[index].completionStoppedDelivered = true
        }
        if markedPlayed {
            reports[index].completionMarkedPlayed = true
        }
        persist()
    }

    func removeAll() {
        reports.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(reports) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }
}

/// The small client surface used by the durable playback layer. Keeping this
/// seam separate from the large REST client makes server routing and retry
/// behavior testable without a network or real Jellyfin credentials.
protocol PlaybackReportingClient: Sendable {
    func reportPlaybackStart(
        itemId: String,
        positionTicks: Int64,
        playSessionId: String?,
        playMethod: String
    ) async throws
    func reportPlaybackProgress(
        itemId: String,
        positionTicks: Int64,
        isPaused: Bool,
        playSessionId: String?
    ) async throws
    func reportPlaybackStopped(
        itemId: String,
        positionTicks: Int64,
        playSessionId: String?
    ) async throws
    func markPlayed(itemId: String) async throws
}

extension JellyfinClient: PlaybackReportingClient {}

private let playbackReportLogger = Logger(
    subsystem: "com.mondominator.sashimi",
    category: "PlaybackReportStore"
)

/// Sends reports immediately and retains failed events until a later active,
/// connected lifecycle. A report is written before its network attempt, so a
/// process termination during the attempt cannot discard the latest state.
@MainActor
final class PlaybackReportDelivery {
    static let shared = PlaybackReportDelivery()

    private let store: PlaybackReportStore
    private var isFlushing = false
    private var inFlightReportIDs = Set<UUID>()

    init(store: PlaybackReportStore? = nil) {
        self.store = store ?? PlaybackReportStore.shared
    }

    @discardableResult
    func enqueue(_ report: PendingPlaybackReport) -> PendingPlaybackReport {
        guard !report.serverID.isEmpty else { return report }
        return store.enqueue(report)
    }

    func sendStart(
        _ report: PendingPlaybackReport,
        playMethod: String,
        client: any PlaybackReportingClient
    ) async {
        var report = report
        report.playMethod = playMethod
        await send(report, client: client, action: { client in
            try await client.reportPlaybackStart(
                itemId: report.itemID,
                positionTicks: report.positionTicks,
                playSessionId: report.playSessionID,
                playMethod: playMethod
            )
        })
    }

    func sendProgress(
        _ report: PendingPlaybackReport,
        client: any PlaybackReportingClient
    ) async {
        await send(report, client: client, action: { client in
            try await client.reportPlaybackProgress(
                itemId: report.itemID,
                positionTicks: report.positionTicks,
                isPaused: report.isPaused,
                playSessionId: report.playSessionID
            )
        })
    }

    func sendStopped(
        _ report: PendingPlaybackReport,
        client: any PlaybackReportingClient
    ) async {
        await send(report, client: client, action: { client in
            try await client.reportPlaybackStopped(
                itemId: report.itemID,
                positionTicks: report.positionTicks,
                playSessionId: report.playSessionID
            )
        })
    }

    func sendCompletion(
        _ report: PendingPlaybackReport,
        client: any PlaybackReportingClient
    ) async {
        if !report.serverID.isEmpty {
            let stored = store.enqueue(report)
            _ = await deliver(stored, using: client)
        } else {
            do {
                try await client.reportPlaybackStopped(
                    itemId: report.itemID,
                    positionTicks: report.positionTicks,
                    playSessionId: report.playSessionID
                )
                try await client.markPlayed(itemId: report.itemID)
            } catch {
                playbackReportLogger.error(
                    "Online completion report failed without a server identity: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    /// Flushes all persisted reports through freshly constructed clients bound
    /// to the report's saved server. It never repoints JellyfinClient.shared.
    func flush() async {
        guard !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        await SessionManager.shared.restoreSession()

        for report in store.reports {
            guard !report.serverID.isEmpty,
                  let client = SessionManager.shared.makeClient(for: report.serverID) else {
                continue
            }
            _ = await deliver(report, using: client)
        }
    }

    @discardableResult
    func deliver(
        _ report: PendingPlaybackReport,
        using client: any PlaybackReportingClient
    ) async -> Bool {
        guard inFlightReportIDs.insert(report.id).inserted else { return false }
        defer { inFlightReportIDs.remove(report.id) }

        do {
            switch report.kind {
            case .start:
                try await client.reportPlaybackStart(
                    itemId: report.itemID,
                    positionTicks: report.positionTicks,
                    playSessionId: report.playSessionID,
                    playMethod: report.playMethod ?? "DirectStream"
                )
            case .progress:
                try await client.reportPlaybackProgress(
                    itemId: report.itemID,
                    positionTicks: report.positionTicks,
                    isPaused: report.isPaused,
                    playSessionId: report.playSessionID
                )
            case .stopped:
                try await client.reportPlaybackStopped(
                    itemId: report.itemID,
                    positionTicks: report.positionTicks,
                    playSessionId: report.playSessionID
                )
            case .completion:
                var updated = report
                if !updated.completionStoppedDelivered {
                    try await client.reportPlaybackStopped(
                        itemId: updated.itemID,
                        positionTicks: updated.positionTicks,
                        playSessionId: updated.playSessionID
                    )
                    updated.completionStoppedDelivered = true
                    store.markCompletionPhase(id: updated.id, stoppedDelivered: true)
                }
                if !updated.completionMarkedPlayed {
                    try await client.markPlayed(itemId: updated.itemID)
                    updated.completionMarkedPlayed = true
                    store.markCompletionPhase(id: updated.id, markedPlayed: true)
                }
            }
            if report.kind == .completion {
                if let current = store.reports.first(where: { $0.id == report.id }) {
                    store.remove(current)
                }
            } else {
                store.remove(report)
            }
            return true
        } catch {
            playbackReportLogger.error(
                "Playback \(report.kind.rawValue, privacy: .public) report queued for retry: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
    }

    private func send(
        _ report: PendingPlaybackReport,
        client: any PlaybackReportingClient,
        action: @escaping (any PlaybackReportingClient) async throws -> Void
    ) async {
        if !report.serverID.isEmpty {
            let stored = store.enqueue(report)
            guard inFlightReportIDs.insert(stored.id).inserted else { return }
            defer { inFlightReportIDs.remove(stored.id) }
            do {
                try await action(client)
                store.remove(stored)
            } catch {
                playbackReportLogger.error(
                    "Playback \(report.kind.rawValue, privacy: .public) report queued for retry: \(error.localizedDescription, privacy: .public)"
                )
            }
        } else {
            do {
                try await action(client)
            } catch {
                playbackReportLogger.error(
                    "Online \(report.kind.rawValue, privacy: .public) report failed without a server identity: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }
}

@MainActor
final class PlaybackSessionReporter {
    private let serverID: String?
    private let client: any PlaybackReportingClient
    private let delivery: PlaybackReportDelivery
    private var hasStarted = false
    private var stopRequested = false
    private var completionRequested = false
    private var pendingStoppedReport: PendingPlaybackReport?

    init(
        serverID: String?,
        client: any PlaybackReportingClient,
        delivery: PlaybackReportDelivery? = nil
    ) {
        self.serverID = serverID
        self.client = client
        self.delivery = delivery ?? PlaybackReportDelivery.shared
    }

    func reset() {
        hasStarted = false
        stopRequested = false
        completionRequested = false
        pendingStoppedReport = nil
    }

    func prepareStopped(itemID: String, positionTicks: Int64, playSessionID: String?) {
        guard hasStarted, !stopRequested, !completionRequested else { return }
        stopRequested = true
        let report = report(
            itemID: itemID,
            positionTicks: positionTicks,
            playSessionID: playSessionID,
            kind: .stopped
        )
        pendingStoppedReport = delivery.enqueue(report)
    }

    func start(itemID: String, positionTicks: Int64, playSessionID: String?, playMethod: String) async {
        guard !hasStarted else { return }
        hasStarted = true
        await delivery.sendStart(
            report(itemID: itemID, positionTicks: positionTicks, playSessionID: playSessionID, kind: .start),
            playMethod: playMethod,
            client: client
        )
    }

    func progress(itemID: String, positionTicks: Int64, isPaused: Bool, playSessionID: String?) async {
        guard hasStarted, !stopRequested, !completionRequested else { return }
        await delivery.sendProgress(
            report(
                itemID: itemID,
                positionTicks: positionTicks,
                playSessionID: playSessionID,
                kind: .progress,
                isPaused: isPaused
            ),
            client: client
        )
    }

    func stopped(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        if let pendingStoppedReport {
            self.pendingStoppedReport = nil
            await delivery.sendStopped(pendingStoppedReport, client: client)
            return
        }
        guard hasStarted, !stopRequested, !completionRequested else { return }
        stopRequested = true
        await delivery.sendStopped(
            report(itemID: itemID, positionTicks: positionTicks, playSessionID: playSessionID, kind: .stopped),
            client: client
        )
    }

    func completed(itemID: String, positionTicks: Int64, playSessionID: String?) async {
        guard hasStarted, !stopRequested, !completionRequested else { return }
        completionRequested = true
        await delivery.sendCompletion(
            report(itemID: itemID, positionTicks: positionTicks, playSessionID: playSessionID, kind: .completion),
            client: client
        )
    }

    private func report(
        itemID: String,
        positionTicks: Int64,
        playSessionID: String?,
        kind: PlaybackReportKind,
        playMethod: String? = nil,
        isPaused: Bool = false
    ) -> PendingPlaybackReport {
        PendingPlaybackReport(
            serverID: serverID ?? "",
            itemID: itemID,
            playSessionID: playSessionID,
            kind: kind,
            playMethod: playMethod,
            positionTicks: positionTicks,
            isPaused: isPaused
        )
    }
}
