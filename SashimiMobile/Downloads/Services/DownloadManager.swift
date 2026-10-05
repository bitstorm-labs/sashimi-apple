import Combine
import Foundation
import os
import SwiftData
import UIKit

// swiftlint:disable type_body_length file_length
// DownloadManager coordinates background downloads, URLSession delegate, and SwiftData persistence:
// a large but cohesive type; splitting it would require a risky refactor of the URLSession delegate wiring.

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()

    nonisolated private static let sessionIdentifier = "com.mondominator.sashimi.mobile.downloads"
    nonisolated private static let taskMapKey = "downloadTaskMap"
    nonisolated private static let taskServerMapKey = "downloadTaskServerMap"

    /// recordID -> shown fraction (0...0.99), or negative when there is
    /// neither a Content-Length nor anything to estimate a total from.
    @Published var activeDownloads: [String: Double] = [:]
    /// recordID -> bytes, total (exact or estimated), speed and time left.
    /// Republished with `activeDownloads` on the progress timer.
    @Published private(set) var progressDetails: [String: DownloadProgressDetail] = [:]
    @Published var stateVersion: Int = 0 // bumped on any download state change
    @Published var downloadSpeed: String = "" // human-readable bandwidth

    // swiftlint:disable:next implicitly_unwrapped_optional
    private var backgroundSession: URLSession!
    private var backgroundCompletionHandler: (() -> Void)?
    private(set) var modelContainer: ModelContainer?
    private var cachedContext: ModelContext?

    // Maps URLSessionTask.taskIdentifier (as String) -> itemId for surviving app relaunches
    // UserDefaults plist format requires String keys, so we store Int taskIdentifiers as Strings
    private var taskIdMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.taskMapKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.taskMapKey) }
    }

    private var taskServerMap: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: Self.taskServerMapKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.taskServerMapKey) }
    }

    private func taskKey(_ taskIdentifier: Int) -> String {
        String(taskIdentifier)
    }

    private func downloadKey(itemId: String, serverID: String?) -> String {
        "\(serverID ?? "legacy"):\(itemId)"
    }

    // Pending image/subtitle downloads (non-background, fire-and-forget)
    private var pendingAssetTasks: [String: [Task<Void, Never>]] = [:]
    /// Downloads whose subtitle files were confirmed complete this launch.
    private var subtitlesVerified: Set<String> = []

    private let persistence = DownloadPersistence()
    private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "DownloadManager")

    private struct ServerDownloadContext {
        let server: ServerConfig
        let token: String
    }

    /// Everything needed to build a download's request, from the item when
    /// it is queued or from its stored record afterwards: a retry or a
    /// relaunch needs no network to queue it again.
    private struct DownloadJob {
        let itemId: String
        let serverID: String?
        var quality: DownloadQuality
        /// Original was confirmed playable on this device (or downgraded).
        var originalVerified = false
        let itemType: ItemType?
        let runTimeTicks: Int64?
        let seriesId: String?

        init(item: BaseItemDto, quality: DownloadQuality, serverID: String?) {
            itemId = item.id
            self.serverID = serverID
            self.quality = quality
            itemType = item.type
            runTimeTicks = item.runTimeTicks
            seriesId = item.seriesId
        }

        init(record: DownloadedItem) {
            itemId = record.itemId
            serverID = record.serverID
            quality = record.downloadQuality
            itemType = record.itemType
            runTimeTicks = record.runTimeTicks
            seriesId = record.seriesId
        }
    }

    /// A download handed to the background session.
    private struct ScheduledTask {
        let recordID: String
        let host: String
    }

    private struct ImageDownload {
        let url: URL?
        let token: String
        let destination: URL
        let itemID: String
        let keyPath: String
        let fileName: String
    }

    /// Queued downloads with no task yet, in queue order: being handed over,
    /// or (Original only) waiting for the server to answer the check.
    private var pendingJobs: [String: DownloadJob] = [:]
    private var pendingOrder: [String] = []
    /// Pending Original downloads whose compatibility check is in flight.
    private var checkingOriginal: Set<String> = []
    /// taskIdentifier -> the download it runs.
    private var scheduledTasks: [Int: ScheduledTask] = [:]
    /// What each scheduled download's row last showed (see recomputeSchedule).
    private var appliedSlots: [String: DownloadTaskSlot] = [:]
    /// Artwork and subtitles are fetched one download at a time.
    private var assetChain: Task<Void, Never>?
    /// Failed downloads already queued again once by the recovery sweep.
    nonisolated private static let recoveredKey = "downloadInterruptionRecovered"

    var queuedCount: Int {
        pendingJobs.count + appliedSlots.values.filter { $0 == .queued }.count
    }

    // Progress throttling
    private var pendingProgress: [String: Double] = [:]
    // recordID -> (written, expected) bytes, for the global progress ring.
    // Not published: activeDownloads republishes on the same timer.
    private var byteCounts: [String: (written: Int64, expected: Int64)] = [:]
    private var lastProgressSave: [String: Date] = [:]
    private var progressTimer: Timer?

    // Smoothed speed per record, sampled on the progress timer.
    private var speedTrackers: [String: DownloadSpeedTracker] = [:]
    /// What each record's size estimate is derived from; mirrored in
    /// UserDefaults (DownloadEstimateStore) so it survives a relaunch.
    private var estimateInputs: [String: DownloadEstimateInput] = [:]

    // In-memory preparing state (items waiting for first bytes from server)
    @Published var preparingItems: Set<String> = []

    // Toast notification
    @Published var toastMessage: String?
    /// Offline progress is being reported (see `syncPendingProgress`).
    private var isSyncingProgress = false

    /// Automatic retries of failed downloads (see DownloadRetryPolicy).
    let retryStore = DownloadRetryStore()
    private var retryTimer: Task<Void, Never>?
    /// Retries started but not yet back in the queue, so overlapping
    /// evaluations don't start one twice.
    private var retriesInFlight: Set<String> = []
    private var cancellables: Set<AnyCancellable> = []
    /// Set once the relaunch reconciliation has run; queue work waits for it
    /// so a task iOS still holds is never handed over a second time.
    private var hasReconciled = false

    override private init() {
        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        // Stays true: "Download over Cellular" is applied to each request
        // (DownloadNetworkPolicy), and false here would override it.
        config.allowsCellularAccess = true
        // The whole queue is handed to the session up front; this is what
        // makes nsurlsessiond run it a couple at a time (see
        // DownloadQueuePolicy.maxConcurrentDownloads).
        config.httpMaximumConnectionsPerHost = DownloadQueuePolicy.maxConcurrentDownloads
        backgroundSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        // Reconnect any in-flight downloads from previous launch
        reconnectTasks()

        NetworkMonitor.shared.downloadStatusPublisher
            .dropFirst()
            .sink { [weak self] _ in self?.downloadConditionsChanged() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.appBecameActive() }
            .store(in: &cancellables)
    }

    private func appBecameActive() {
        guard hasReconciled else { return }
        recoverInterruptedFailures()
        evaluateRetries()
        handOffPending()
    }

    func setModelContainer(_ container: ModelContainer) {
        self.modelContainer = container
        // The container's own main context, i.e. the one the views' @Query
        // observes. A separate ModelContext(container) here meant a newly
        // queued record reached the Downloads list only if and when SwiftData
        // merged that sibling context's save into the main one; an insert
        // into the observed context itself needs no merge.
        self.cachedContext = container.mainContext
        persistence.setModelContainer(container)
    }

    /// The main-actor context for reads and for the writes the UI must see
    /// at once (new and deleted records).
    private var mainContext: ModelContext? {
        cachedContext
    }

    func setBackgroundCompletionHandler(_ handler: @escaping () -> Void) {
        backgroundCompletionHandler = handler
    }

    // MARK: - Progress Timer

    private func startProgressTimer() {
        guard progressTimer == nil else { return }
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.publishProgress()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func publishProgress() {
        guard !pendingProgress.isEmpty else { return }
        let now = Date().timeIntervalSinceReferenceDate
        var details: [String: DownloadProgressDetail] = [:]
        var fractions: [String: Double] = [:]
        for key in pendingProgress.keys {
            speedTrackers[key, default: DownloadSpeedTracker()]
                .record(totalBytes: byteCounts[key]?.written ?? 0, at: now)
            let detail = progressDetail(for: key)
            details[key] = detail
            fractions[key] = detail.display.fraction ?? -1
        }
        progressDetails = details
        activeDownloads = fractions

        // Combined across everything running at once.
        let rates = details.values.compactMap(\.bytesPerSecond)
        let speed = rates.isEmpty ? "" : DownloadProgressText.speed(rates.reduce(0, +))
        if downloadSpeed != speed { downloadSpeed = speed }
    }

    /// Bytes, total and speed for one in-flight download. The total is the
    /// server's Content-Length when it sent one, else the estimate.
    private func progressDetail(for key: String) -> DownloadProgressDetail {
        let bytes = byteCounts[key]
        return DownloadProgressDetail.make(
            receivedBytes: bytes?.written ?? 0,
            exactTotalBytes: bytes?.expected,
            estimatedTotalBytes: estimateInput(for: key).flatMap(DownloadSizeEstimate.expectedBytes(for:)),
            bytesPerSecond: speedTrackers[key]?.bytesPerSecond
        )
    }

    private func estimateInput(for key: String) -> DownloadEstimateInput? {
        if let cached = estimateInputs[key] { return cached }
        // After a relaunch: the task kept running, the memory didn't.
        guard let stored = DownloadEstimateStore.input(recordID: key) else { return nil }
        estimateInputs[key] = stored
        return stored
    }

    private func updateEstimateInput(for key: String, _ change: (inout DownloadEstimateInput) -> Void) {
        var input = estimateInput(for: key) ?? DownloadEstimateInput()
        change(&input)
        estimateInputs[key] = input
        DownloadEstimateStore.set(input, recordID: key)
    }

    /// The source's bitrates, from playback info that is fetched anyway (the
    /// Original compatibility check, the subtitle list): the server caps a
    /// transcode's video at the source's, and an Original is the source.
    private func noteSource(_ source: MediaSourceInfo, for key: String) {
        let video = source.mediaStreams?.first { $0.type == "Video" }?.bitRate
        guard source.bitrate != nil || video != nil else { return }
        updateEstimateInput(for: key) { input in
            input.sourceBitrate = source.bitrate ?? input.sourceBitrate
            input.sourceVideoBitrate = video ?? input.sourceVideoBitrate
        }
    }

    private func forgetEstimate(for key: String) {
        estimateInputs.removeValue(forKey: key)
        DownloadEstimateStore.forget(recordID: key)
    }

    /// Drops every piece of in-flight progress state for a record.
    private func clearProgress(for key: String) {
        pendingProgress.removeValue(forKey: key)
        byteCounts.removeValue(forKey: key)
        activeDownloads.removeValue(forKey: key)
        progressDetails.removeValue(forKey: key)
        speedTrackers.removeValue(forKey: key)
        preparingItems.remove(key)
        lastProgressSave.removeValue(forKey: key)
    }

    // MARK: - Public API

    /// Count and overall progress for the global download indicator.
    var activitySnapshot: DownloadActivitySnapshot {
        let active = activeDownloads.reduce(into: [String: DownloadItemProgress]()) { result, entry in
            // The shown total, so an estimated-size download counts toward
            // the ring the same way an exact one does.
            let display = progressDetails[entry.key]?.display
            result[entry.key] = DownloadItemProgress(
                fraction: entry.value,
                bytesWritten: display?.receivedBytes ?? 0,
                bytesExpected: display?.totalBytes ?? 0
            )
        }
        return DownloadActivitySnapshot(active: active, preparingKeys: preparingItems, queuedCount: queuedCount)
    }

    /// A new download (the user's, or keep-next's). Starts with a clean
    /// automatic-retry count.
    func enqueueDownload(item: BaseItemDto, quality: DownloadQuality, serverID: String? = nil) {
        let resolvedServerID = serverID ?? SessionManager.shared.activeServerId
        guard enqueue(item: item, quality: quality, serverID: resolvedServerID) else { return }
        retryStore.clear(itemId: item.id, serverID: resolvedServerID)
        announceIfWaitingForNetwork(count: 1)
    }

    private func enqueue(item: BaseItemDto, quality: DownloadQuality, serverID: String?) -> Bool {
        guard insertQueuedRecord(item: item, quality: quality, serverID: serverID) else { return false }
        addPending(DownloadJob(item: item, quality: quality, serverID: serverID))
        stateVersion += 1
        handOffPending()
        return true
    }

    /// Queued while downloads can't use this network: say so, or a tap on
    /// Download looks like it did nothing.
    private func announceIfWaitingForNetwork(count: Int) {
        let reason = DownloadNetworkPolicy.waitReason(
            allowCellular: DownloadNetworkPolicy.allowsCellular,
            network: .current
        )
        let subject = count == 1 ? "Will download" : "\(count) episodes will download"
        switch reason {
        case .cellular: toastMessage = "\(subject) on Wi-Fi"
        case .lowDataMode: toastMessage = "\(subject) when Low Data Mode is off"
        case .offline, nil: break
        }
    }

    /// Insert a queued download record on the main actor's context so @Query sees it immediately.
    private func insertQueuedRecord(item: BaseItemDto, quality: DownloadQuality, serverID: String?) -> Bool {
        guard let context = mainContext else { return false }
        let itemId = item.id
        let existing = mainRecord(itemId: itemId, serverID: serverID)
        if let existing {
            if existing.status == .completed || existing.status == .downloading
                || existing.status == .preparing || existing.status == .queued {
                return false
            }
            context.delete(existing)
        }
        let record = DownloadedItem(
            itemId: itemId,
            name: item.name,
            itemType: item.type ?? .unknown,
            quality: quality,
            serverID: serverID,
            seriesName: item.seriesName,
            seasonNumber: item.parentIndexNumber,
            episodeNumber: item.indexNumber,
            overview: item.overview,
            runTimeTicks: item.runTimeTicks,
            productionYear: item.productionYear,
            seriesId: item.seriesId,
            seasonId: item.seasonId
        )
        context.insert(record)
        try? context.save()
        return true
    }

    private func mainRecord(itemId: String, serverID: String?) -> DownloadedItem? {
        guard let context = mainContext,
              let records = try? context.fetch(FetchDescriptor<DownloadedItem>()) else { return nil }
        if let serverID {
            if let exact = records.first(where: { $0.itemId == itemId && $0.serverID == serverID }) {
                return exact
            }
            guard serverID == SessionManager.shared.activeServerId,
                  let legacy = records.first(where: { $0.itemId == itemId && $0.serverID == nil }) else {
                return nil
            }
            // Bind pre-multi-server records to the active server before they
            // are reused. Move their files so the old download remains intact.
            guard (try? DownloadFileManager.migrateItemDirectory(itemId: itemId, to: serverID)) == true else {
                return nil
            }
            legacy.serverID = serverID
            try? context.save()
            return legacy
        }
        return records.first { $0.itemId == itemId && $0.serverID == nil }
            ?? records.first { $0.itemId == itemId }
    }

    // MARK: - Handing downloads to the session

    private func addPending(_ job: DownloadJob, atFront: Bool = false) {
        let key = downloadKey(itemId: job.itemId, serverID: job.serverID)
        pendingJobs[key] = job
        pendingOrder.removeAll { $0 == key }
        if atFront {
            pendingOrder.insert(key, at: 0)
        } else {
            pendingOrder.append(key)
        }
    }

    private func removePending(_ key: String) {
        pendingJobs.removeValue(forKey: key)
        pendingOrder.removeAll { $0 == key }
        checkingOriginal.remove(key)
    }

    /// Creates a background task for every queued download that has none,
    /// at once: nsurlsessiond runs them in turn whether or not the app is
    /// awake. Only an Original download asks the server anything first.
    private func handOffPending() {
        guard hasReconciled else { return }
        let freeBytes = DownloadFileManager.availableDiskSpace()
        var originals: [String] = []
        for key in pendingOrder {
            guard let job = pendingJobs[key], !checkingOriginal.contains(key) else { continue }
            let status = mainRecord(itemId: job.itemId, serverID: job.serverID)?.status
            guard status == .queued || status == .downloading || status == .preparing,
                  !scheduledTasks.values.contains(where: { $0.recordID == key }) else {
                removePending(key) // Cancelled, finished, or already handed over.
                continue
            }
            switch DownloadHandOff.step(quality: job.quality, originalVerified: job.originalVerified, freeBytes: freeBytes) {
            case .handOver:
                handOver(job)
            case .checkOriginal:
                originals.append(key)
            case .fail(let message):
                removePending(key)
                markFailed(itemId: job.itemId, serverID: job.serverID, message: message, kind: .permanent)
            }
        }
        guard !originals.isEmpty else { return }
        originals.forEach { checkingOriginal.insert($0) }
        // The checks need the network; finish them even if the app is
        // backgrounded straight after queueing.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "check-original-downloads")
        Task { [weak self] in
            defer {
                if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
            }
            for key in originals {
                await self?.checkOriginal(key: key)
            }
        }
    }

    /// For Original: downgrades to High unless the source can direct-play
    /// here, persisting the downgrade so the row shows what is downloaded.
    /// If the server can't be reached the download stays queued and the
    /// check runs again when the app is active or the network changes.
    private func checkOriginal(key: String) async {
        guard var job = pendingJobs[key] else { return }
        let compatible: Result<Bool, Error>
        do {
            // Downloads stay on the AVPlayer profile until Phase 5: an MKV
            // downloaded under a VLC profile would be one AVPlayer can't open.
            let client = try await client(for: job.serverID)
            let info = try await client.getPlaybackInfo(itemId: job.itemId, engine: .avFoundation)
            if let source = info.mediaSources?.first {
                noteSource(source, for: key)
            }
            compatible = .success(info.mediaSources?.first.map { DeviceMediaCompatibility.canRemuxForDownload($0) } ?? false)
        } catch {
            compatible = .failure(error)
        }

        checkingOriginal.remove(key)
        // Cancelled while the check was in flight.
        guard pendingJobs[key] != nil else { return }
        switch DownloadHandOff.originalCheckOutcome(compatible) {
        case .waitForNetwork:
            return
        case .quality(let effective):
            if effective != job.quality, let context = mainContext,
               let record = mainRecord(itemId: job.itemId, serverID: job.serverID) {
                // The main context is what the @Query-backed rows observe.
                record.downloadQuality = effective
                try? context.save()
            }
            job.quality = effective
            job.originalVerified = true
            pendingJobs[key] = job
            handOffPending()
        }
    }

    /// Builds the request with the (already-resolved) quality and creates
    /// the background task. The row stays Queued until the session gives
    /// the task a connection (recomputeSchedule).
    private func handOver(_ job: DownloadJob) {
        let itemId = job.itemId
        let serverID = job.serverID
        let key = downloadKey(itemId: itemId, serverID: serverID)
        removePending(key)

        // URLRequest (not bare URL) so the token travels in a header and the
        // background task keeps it across app relaunches.
        guard let context = serverContext(for: serverID),
              let downloadURL = DownloadURLBuilder.downloadURL(
                  itemId: itemId,
                  quality: job.quality,
                  serverURL: context.server.url
              ),
              var downloadRequest = DownloadURLBuilder.authorizedRequest(
                  for: downloadURL,
                  accessToken: context.token
              ) else {
            // No server or token for it: retrying can't help until sign-in.
            markFailed(itemId: itemId, serverID: serverID, message: "Could not build download URL", kind: .permanent)
            return
        }
        // Per task: each request carries the cellular / Low Data Mode rule
        // in force when it was created (see reconcileTaskNetworkAccess).
        DownloadNetworkPolicy.apply(to: &downloadRequest, allowCellular: DownloadNetworkPolicy.allowsCellular)
        if job.quality != .original {
            DownloadEncodingAudit.markEncodedWithVideoBitrate(recordID: key)
        }

        do {
            try DownloadFileManager.createItemDirectory(for: itemId, serverID: serverID)
        } catch {
            markFailed(
                itemId: itemId,
                serverID: serverID,
                message: "Could not create directory: \(error.localizedDescription)",
                kind: DownloadRetryPolicy.classify(error: error)
            )
            return
        }

        let task = backgroundSession.downloadTask(with: downloadRequest)
        var map = taskIdMap
        map[taskKey(task.taskIdentifier)] = itemId
        taskIdMap = map
        var serverMap = taskServerMap
        if let serverID {
            serverMap[taskKey(task.taskIdentifier)] = serverID
        }
        taskServerMap = serverMap
        scheduledTasks[task.taskIdentifier] = ScheduledTask(recordID: key, host: Self.hostKey(for: downloadURL))
        byteCounts.removeValue(forKey: key)
        speedTrackers.removeValue(forKey: key)
        updateEstimateInput(for: key) { input in
            input.quality = job.quality.rawValue
            input.runTimeTicks = job.runTimeTicks
        }
        task.resume()
        recomputeSchedule()

        fetchAssets(for: job, server: context.server, token: context.token)
    }

    nonisolated private static func hostKey(for url: URL?) -> String {
        guard let url else { return "" }
        return "\(url.host ?? ""):\(url.port.map(String.init) ?? url.scheme ?? "")"
    }

    /// Re-derives which handed-over downloads are running and which are
    /// waiting their turn, and shows that: a task waiting behind the limit is
    /// Queued (no progress, no "Preparing..."), one with a connection but no
    /// bytes is Preparing, and one receiving bytes is Downloading.
    private func recomputeSchedule() {
        let entries = scheduledTasks.map { taskIdentifier, scheduled in
            DownloadTaskSchedule.Entry(
                recordID: scheduled.recordID,
                host: scheduled.host,
                taskIdentifier: taskIdentifier,
                bytesReceived: byteCounts[scheduled.recordID]?.written ?? 0
            )
        }
        let slots = DownloadTaskSchedule.slots(entries)
        for (key, slot) in slots {
            switch slot {
            case .queued:
                pendingProgress.removeValue(forKey: key)
                activeDownloads.removeValue(forKey: key)
                progressDetails.removeValue(forKey: key)
                preparingItems.remove(key)
            case .preparing:
                if pendingProgress[key] == nil { pendingProgress[key] = 0 }
                preparingItems.insert(key)
            case .downloading:
                if pendingProgress[key] == nil { pendingProgress[key] = 0 }
                preparingItems.remove(key)
            }
            guard appliedSlots[key] != slot else { continue }
            let wasQueued = appliedSlots[key].map { $0 == .queued } ?? true
            appliedSlots[key] = slot
            if wasQueued != (slot == .queued), let (itemId, serverID) = Self.splitKey(key) {
                persistence.updateStatus(itemId: itemId, serverID: serverID, status: slot == .queued ? .queued : .downloading)
            }
        }
        for key in appliedSlots.keys where slots[key] == nil {
            appliedSlots.removeValue(forKey: key)
        }
        if slots.values.contains(where: { $0 != .queued }) {
            startProgressTimer()
        } else {
            stopProgressTimer()
            pendingProgress.removeAll()
            if !downloadSpeed.isEmpty { downloadSpeed = "" }
        }
        stateVersion += 1
    }

    /// Writes a status on the main context, so the rows and the queue see
    /// it at once.
    private func setStatus(_ record: DownloadedItem, _ status: DownloadStatus, errorMessage: String? = nil) {
        record.status = status
        record.errorMessage = errorMessage
        try? mainContext?.save()
    }

    /// "server:item" back into its parts ("legacy" is a record without one).
    nonisolated private static func splitKey(_ key: String) -> (itemId: String, serverID: String?)? {
        guard let colon = key.firstIndex(of: ":") else { return nil }
        let server = String(key[..<colon])
        return (String(key[key.index(after: colon)...]), server == "legacy" ? nil : server)
    }

    /// Forgets a task the app no longer tracks (finished, failed, cancelled).
    private func forgetTask(_ taskIdentifier: Int) {
        var map = taskIdMap
        map.removeValue(forKey: taskKey(taskIdentifier))
        taskIdMap = map
        var serverMap = taskServerMap
        serverMap.removeValue(forKey: taskKey(taskIdentifier))
        taskServerMap = serverMap
        scheduledTasks.removeValue(forKey: taskIdentifier)
    }

    /// Cancels every task running a download (there is normally one).
    private func cancelTasks(for key: String) async {
        for task in await backgroundSession.allTasks
        where scheduledTasks[task.taskIdentifier]?.recordID == key || taskRecordID(task.taskIdentifier) == key {
            forgetTask(task.taskIdentifier)
            task.cancel()
        }
    }

    private func taskRecordID(_ taskIdentifier: Int) -> String? {
        taskIdMap[taskKey(taskIdentifier)].map { downloadKey(itemId: $0, serverID: taskServerMap[taskKey(taskIdentifier)]) }
    }

    /// The device slept, the app was suspended or killed, or the network
    /// dropped: the download goes back to Queued without using a retry, and
    /// is handed over again once the app is active.
    private func requeueInterrupted(itemId: String, serverID: String?) {
        let key = downloadKey(itemId: itemId, serverID: serverID)
        clearProgress(for: key)
        appliedSlots.removeValue(forKey: key)
        if let record = mainRecord(itemId: itemId, serverID: serverID) {
            setStatus(record, .queued)
            var job = DownloadJob(record: record)
            job.originalVerified = true // Checked when it was first handed over.
            addPending(job, atFront: true)
        }
        stateVersion += 1
        if UIApplication.shared.applicationState == .active {
            handOffPending()
        }
    }

    private func deleteRecordFromMainContext(itemId: String, serverID: String?) {
        guard let context = mainContext,
              let record = mainRecord(itemId: itemId, serverID: serverID) else { return }
        context.delete(record)
        try? context.save()
    }

    func cancelDownload(itemId: String, serverID: String? = nil) async {
        let tasks = await backgroundSession.allTasks
        var cancelledKeys: Set<String> = []
        for task in tasks where taskIdMap[taskKey(task.taskIdentifier)] == itemId
            && (serverID == nil || taskServerMap[taskKey(task.taskIdentifier)] == serverID) {
            if let key = taskRecordID(task.taskIdentifier) { cancelledKeys.insert(key) }
            forgetTask(task.taskIdentifier)
            task.cancel()
        }

        let key = downloadKey(itemId: itemId, serverID: serverID)
        cancelledKeys.insert(key)
        if serverID == nil {
            // Unscoped: whatever server's copy of this item is queued.
            pendingJobs.values.filter { $0.itemId == itemId }
                .forEach { cancelledKeys.insert(downloadKey(itemId: $0.itemId, serverID: $0.serverID)) }
        }
        for cancelled in cancelledKeys {
            removePending(cancelled)
            appliedSlots.removeValue(forKey: cancelled)
            pendingAssetTasks[cancelled]?.forEach { $0.cancel() }
            pendingAssetTasks.removeValue(forKey: cancelled)
            clearProgress(for: cancelled)
        }
        forgetEstimate(for: key)

        try? DownloadFileManager.deleteItemDirectory(for: itemId, serverID: serverID)
        deleteRecordFromMainContext(itemId: itemId, serverID: serverID)
        DownloadEncodingAudit.forget(recordID: key)
        recomputeSchedule()
    }

    func deleteDownload(itemId: String, serverID: String? = nil) async {
        await cancelDownload(itemId: itemId, serverID: serverID)
        retryStore.clear(itemId: itemId, serverID: serverID)
        stateVersion += 1
    }

    /// Deletes several completed downloads at once (Remove watched, Edit-mode
    /// delete) with one state bump and one toast.
    func deleteDownloads(_ items: [(itemId: String, serverID: String?)]) async {
        guard !items.isEmpty else { return }
        for item in items {
            await cancelDownload(itemId: item.itemId, serverID: item.serverID)
            retryStore.clear(itemId: item.itemId, serverID: item.serverID)
        }
        stateVersion += 1
        toastMessage = "Deleted \(items.count) download\(items.count == 1 ? "" : "s")"
    }

    /// Called once the player is gone after a downloaded item played to its
    /// end. With "Delete downloads after watching" on, the completion is handed
    /// to the durable report queue (so the server still learns it was watched
    /// after the local record is gone) and the download is deleted.
    func handleOfflinePlaybackFinished(itemId: String, serverID: String?) async {
        let record = downloadStatus(for: itemId, serverID: serverID)
        let enabled = UserDefaults.standard.bool(forKey: DownloadWatchPolicy.deleteAfterWatchingKey)
        guard DownloadWatchPolicy.shouldAutoDelete(
            settingEnabled: enabled,
            isCompletedDownload: record?.isComplete == true,
            playedToEnd: true
        ), let record else { return }

        let recordServerID = record.serverID
        let resolvedServerID = recordServerID ?? serverID ?? SessionManager.shared.activeServerId
        let name = record.displayTitle
        // Persisted before the delete; sent after it, so an unreachable server
        // never holds the delete up. The queue retries on the next launch.
        let report = resolvedServerID.map {
            PlaybackReportDelivery.shared.enqueue(PendingPlaybackReport(
                serverID: $0,
                itemID: itemId,
                playSessionID: nil,
                kind: .completion,
                positionTicks: record.runTimeTicks ?? record.lastPlaybackPositionTicks
            ))
        }

        await cancelDownload(itemId: itemId, serverID: recordServerID)
        stateVersion += 1
        toastMessage = "Deleted \(name) after watching"

        if let report, let client = SessionManager.shared.makeClient(for: report.serverID) {
            Task { await PlaybackReportDelivery.shared.deliver(report, using: client) }
        }
    }

    /// Restarts a download from scratch. `userInitiated` (a Retry tap) also
    /// resets the automatic-retry count; the automatic retries and the
    /// relaunch requeue pass false so the count survives them.
    func retryDownload(itemId: String, serverID: String? = nil, userInitiated: Bool = true) async {
        guard let record = downloadStatus(for: itemId, serverID: serverID) else { return }
        let resolvedServerID = record.serverID
        if userInitiated {
            retryStore.clear(itemId: itemId, serverID: resolvedServerID)
        }
        requeueFromScratch(record)
        if userInitiated {
            announceIfWaitingForNetwork(count: 1)
        }
    }

    /// Starts a download over from its stored record: the old task and files
    /// go, the record is reset to Queued and handed to the session again. Its
    /// metadata is what was saved when it was queued, so this works offline
    /// (the task then waits for the network) -- it used to refetch the item
    /// first, and fail with "Could not fetch item info" when it couldn't.
    private func requeueFromScratch(_ record: DownloadedItem) {
        let itemId = record.itemId
        let serverID = record.serverID
        let key = downloadKey(itemId: itemId, serverID: serverID)
        let cancelled = scheduledTasks.filter { $0.value.recordID == key }.map(\.key)
        cancelled.forEach(forgetTask)
        if !cancelled.isEmpty {
            backgroundSession.getAllTasks { tasks in
                tasks.filter { cancelled.contains($0.taskIdentifier) }.forEach { $0.cancel() }
            }
        }
        removePending(key)
        appliedSlots.removeValue(forKey: key)
        pendingAssetTasks[key]?.forEach { $0.cancel() }
        pendingAssetTasks.removeValue(forKey: key)
        clearProgress(for: key)
        forgetEstimate(for: key)
        DownloadEncodingAudit.forget(recordID: key)
        try? DownloadFileManager.deleteItemDirectory(for: itemId, serverID: serverID)

        for subtitle in record.subtitles {
            mainContext?.delete(subtitle)
        }
        record.subtitles = []
        record.videoFileName = nil
        record.posterFileName = nil
        record.backdropFileName = nil
        record.progress = 0
        record.downloadedBytes = 0
        record.totalBytes = 0
        record.dateCompleted = nil
        subtitlesVerified.remove(key)
        setStatus(record, .queued)

        addPending(DownloadJob(record: record))
        recomputeSchedule()
        handOffPending()
    }

    /// Whether a completed download was made by the pre-fix transcode URL
    /// (1 kbps video) and should be downloaded again.
    func needsRedownload(_ item: DownloadedItem, fixedRecordIDs: Set<String> = DownloadEncodingAudit.fixedRecordIDs()) -> Bool {
        DownloadEncodingAudit.needsRedownload(
            quality: item.downloadQuality,
            isComplete: item.isComplete,
            recordID: item.recordID,
            fixedRecordIDs: fixedRecordIDs
        )
    }

    /// Replaces unwatchable pre-fix downloads: each file is deleted and the
    /// download queued again at its own quality, from its stored record --
    /// offline it waits for the network as Queued instead of failing.
    func redownload(_ items: [(itemId: String, serverID: String?)]) async {
        guard !items.isEmpty else { return }
        for item in items {
            await retryDownload(itemId: item.itemId, serverID: item.serverID, userInitiated: true)
        }
        toastMessage = items.count == 1 ? "Downloading again" : "Downloading \(items.count) items again"
    }

    // MARK: - Failure and automatic retry

    /// Marks a download failed and, for a transient failure, schedules its
    /// next automatic retry.
    private func markFailed(itemId: String, serverID: String?, message: String, kind: DownloadFailureKind) {
        persistence.updateStatus(itemId: itemId, serverID: serverID, status: .failed, errorMessage: message)
        retryStore.recordFailure(itemId: itemId, serverID: serverID, kind: kind)
        stateVersion += 1
        evaluateRetries()
    }

    /// The failed row's retry note: "Retrying in 5 min", "Will retry on
    /// Wi-Fi", or nil when no automatic retry is coming.
    func retryLabel(for item: DownloadedItem, now: Date, waitReason: DownloadWaitReason?) -> String? {
        guard item.status == .failed,
              let next = retryStore.entry(itemId: item.itemId, serverID: item.serverID)?.nextRetryAt else { return nil }
        return DownloadRetryPolicy.label(nextRetryAt: next, now: now, waitReason: waitReason)
    }

    /// Fires the retries that are due (when downloads may use the network)
    /// and sets a timer for the next one. Runs on every failure, network
    /// change, setting change and return to the foreground; a suspended app
    /// catches up when it is next opened.
    func evaluateRetries() {
        retryTimer?.cancel()
        retryTimer = nil
        let now = Date()

        for entry in retryStore.entries.values {
            guard let record = mainRecord(itemId: entry.itemId, serverID: entry.serverID) else {
                // Deleted (or never re-created): nothing left to retry.
                retryStore.clear(itemId: entry.itemId, serverID: entry.serverID)
                continue
            }
            if record.status == .completed {
                retryStore.clear(itemId: entry.itemId, serverID: entry.serverID)
            }
        }

        let canDownload = DownloadNetworkPolicy.canDownloadNow(
            allowCellular: DownloadNetworkPolicy.allowsCellular,
            network: .current
        )
        if canDownload {
            // A retry in flight keeps its entry (its record is queued or
            // downloading, not failed) until it completes or fails again.
            let due = retryStore.due(at: now).filter {
                !retriesInFlight.contains(downloadKey(itemId: $0.itemId, serverID: $0.serverID))
                    && mainRecord(itemId: $0.itemId, serverID: $0.serverID)?.status == .failed
            }
            due.forEach { retriesInFlight.insert(downloadKey(itemId: $0.itemId, serverID: $0.serverID)) }
            if !due.isEmpty {
                Task {
                    for entry in due {
                        await retryDownload(itemId: entry.itemId, serverID: entry.serverID, userInitiated: false)
                        retriesInFlight.remove(downloadKey(itemId: entry.itemId, serverID: entry.serverID))
                    }
                }
            }
        }

        if let next = retryStore.nextRetryDate(after: now) {
            let wait = next.timeIntervalSince(now) + 1
            retryTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard !Task.isCancelled else { return }
                self?.evaluateRetries()
            }
        }
    }

    // MARK: - Network setting

    /// "Download over Cellular" was toggled.
    func downloadNetworkSettingChanged() {
        downloadConditionsChanged()
        KeepNextEpisodesService.shared.scheduleSync()
    }

    private func downloadConditionsChanged() {
        stateVersion += 1
        guard hasReconciled else { return }
        evaluateRetries()
        // Original checks that waited for the network, and downloads
        // requeued by an outage.
        handOffPending()
        Task { await reconcileTaskNetworkAccess() }
    }

    /// A task keeps the network access it was created with; recreate any
    /// whose access no longer matches the setting on the current network
    /// (see DownloadNetworkPolicy.shouldRestartTask).
    private func reconcileTaskNetworkAccess() async {
        let allowCellular = DownloadNetworkPolicy.allowsCellular
        let network = DownloadNetworkStatus.current
        var restarted = false
        for task in await backgroundSession.allTasks.sorted(by: { $0.taskIdentifier < $1.taskIdentifier }) {
            let key = taskKey(task.taskIdentifier)
            guard task.state == .running || task.state == .suspended,
                  let itemId = taskIdMap[key],
                  DownloadNetworkPolicy.shouldRestartTask(
                      taskAllowsCellular: task.originalRequest?.allowsCellularAccess ?? true,
                      allowCellular: allowCellular,
                      network: network
                  ) else { continue }
            restartTask(task, itemId: itemId, serverID: taskServerMap[key])
            restarted = true
        }
        guard restarted else { return }
        recomputeSchedule()
        handOffPending()
    }

    /// Cancels a task and queues its download to be handed over again,
    /// keeping its record, so the new task picks up the current setting.
    /// Rebuilt from the record: no network needed.
    private func restartTask(_ task: URLSessionTask, itemId: String, serverID: String?) {
        let key = taskKey(task.taskIdentifier)
        guard taskIdMap[key] == itemId else { return } // Finished or cancelled meanwhile.
        forgetTask(task.taskIdentifier)
        task.cancel()

        let recordKey = downloadKey(itemId: itemId, serverID: serverID)
        clearProgress(for: recordKey)
        appliedSlots.removeValue(forKey: recordKey)
        if let record = mainRecord(itemId: itemId, serverID: serverID) {
            setStatus(record, .queued)
            var job = DownloadJob(record: record)
            job.originalVerified = true
            addPending(job)
        }
    }

    func downloadStatus(for itemId: String, serverID: String? = nil) -> DownloadedItem? {
        mainRecord(itemId: itemId, serverID: serverID ?? SessionManager.shared.activeServerId)
    }

    func isDownloaded(itemId: String, serverID: String? = nil) -> Bool {
        downloadStatus(for: itemId, serverID: serverID)?.isComplete ?? false
    }

    func localVideoURL(for itemId: String, serverID: String? = nil) -> URL? {
        guard let record = downloadStatus(for: itemId, serverID: serverID), record.isComplete else { return nil }
        return record.videoFileURL
    }

    /// The downloaded subtitle tracks for an item, in a form the shared player
    /// can consume. Without this the .vtt files written at download time were
    /// never read by anything.
    func offlineSubtitles(for itemId: String, serverID: String? = nil) -> [OfflineSubtitle] {
        guard let record = downloadStatus(for: itemId, serverID: serverID) else { return [] }
        return record.subtitles.compactMap { subtitle in
            let url = DownloadFileManager.subtitlesDirectory(for: itemId, serverID: record.serverID)
                .appendingPathComponent(subtitle.fileName)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return OfflineSubtitle(
                index: subtitle.subtitleIndex,
                language: subtitle.language,
                displayTitle: subtitle.displayTitle,
                fileURL: url
            )
        }
    }

    func offlinePlaybackPosition(for itemId: String, serverID: String? = nil) -> Int64? {
        guard let record = downloadStatus(for: itemId, serverID: serverID) else { return nil }
        return record.lastPlaybackPositionTicks > 0 ? record.lastPlaybackPositionTicks : nil
    }

    // MARK: - Offline Progress Tracking

    func savePlaybackPosition(itemId: String, serverID: String? = nil, positionTicks: Int64) {
        persistence.savePlaybackPosition(
            itemId: itemId,
            serverID: serverID,
            positionTicks: positionTicks,
            didSave: Self.noteOfflineProgressChanged
        )
    }

    /// Reports positions saved while offline. Runs at launch and whenever the
    /// app comes back online; overlapping calls (a reconnect during the launch
    /// sync) are dropped so no position is reported twice.
    func syncPendingProgress() async {
        guard !isSyncingProgress else { return }
        isSyncingProgress = true
        defer { isSyncingProgress = false }
        let pendingItems = persistence.fetchPendingSync()
        for item in pendingItems {
            do {
                let client = try await client(for: item.serverID)
                try await client.reportPlaybackStopped(
                    itemId: item.itemID,
                    positionTicks: item.positionTicks
                )
                persistence.clearSyncFlag(
                    itemId: item.itemID,
                    serverID: item.serverID,
                    didSave: Self.noteOfflineProgressChanged
                )
            } catch {
                // Server unreachable — retried on the next launch or reconnect
            }
        }
    }

    /// A saved or synced offline position changes what the offline screens
    /// show (progress, watched, the sync badge); bump the state they observe.
    nonisolated private static func noteOfflineProgressChanged() {
        Task { @MainActor in
            DownloadManager.shared.stateVersion += 1
        }
    }

    // MARK: - Season Downloads

    func downloadSeason(episodes: [BaseItemDto], quality: DownloadQuality, serverID: String? = nil) {
        let serverID = serverID ?? SessionManager.shared.activeServerId
        let inserted = episodes.filter { insertQueuedRecord(item: $0, quality: quality, serverID: serverID) }
        for episode in inserted {
            addPending(DownloadJob(item: episode, quality: quality, serverID: serverID))
        }
        let insertedCount = inserted.count
        guard insertedCount > 0 else { return }
        inserted.forEach { retryStore.clear(itemId: $0.id, serverID: serverID) }

        stateVersion += 1
        toastMessage = "Downloading \(insertedCount) episode\(insertedCount == 1 ? "" : "s")..."
        announceIfWaitingForNetwork(count: insertedCount)
        handOffPending()
    }

    // MARK: - Delete All

    func deleteAllDownloads() async {
        // Cancel all active tasks
        let tasks = await backgroundSession.allTasks
        tasks.forEach { $0.cancel() }
        taskIdMap = [:]
        taskServerMap = [:]
        activeDownloads = [:]
        progressDetails = [:]
        speedTrackers.removeAll()
        estimateInputs.removeAll()
        DownloadEstimateStore.clearAll()

        pendingJobs.removeAll()
        pendingOrder.removeAll()
        checkingOriginal.removeAll()
        scheduledTasks.removeAll()
        appliedSlots.removeAll()
        pendingAssetTasks.values.flatMap { $0 }.forEach { $0.cancel() }
        pendingAssetTasks.removeAll()
        retryStore.clearAll()
        pendingProgress.removeAll()
        byteCounts.removeAll()
        preparingItems.removeAll()
        lastProgressSave.removeAll()
        stopProgressTimer()

        // Delete all files
        try? DownloadFileManager.deleteAllDownloads()

        // Delete all records
        persistence.deleteAllRecords()
    }

    // MARK: - Private Helpers

    private func serverContext(for serverID: String?) -> ServerDownloadContext? {
        let resolvedServerID = serverID ?? SessionManager.shared.activeServerId
        guard let resolvedServerID,
              let server = SessionManager.shared.servers.first(where: { $0.id == resolvedServerID }),
              let token = SessionManager.shared.token(for: server, allowLegacyFallback: true) else {
            return nil
        }
        return ServerDownloadContext(server: server, token: token)
    }

    private func client(for serverID: String?) async throws -> JellyfinClient {
        guard let context = serverContext(for: serverID) else {
            throw JellyfinError.notConfigured
        }
        let client = JellyfinClient()
        await client.configure(
            serverURL: context.server.url,
            accessToken: context.token,
            userId: context.server.userId
        )
        return client
    }

    /// After a launch: adopts the tasks the session still holds, cancels any
    /// that belong to nothing (or duplicate another), and hands every
    /// unfinished download without a task to the session again -- with no
    /// retry attempt used and no server call needed.
    private func reconnectTasks() {
        backgroundSession.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                self?.reconcile(with: tasks)
            }
        }
    }

    private func reconcile(with tasks: [URLSessionTask]) {
        guard let context = mainContext,
              let records = try? context.fetch(FetchDescriptor<DownloadedItem>()) else {
            // No store yet (setModelContainer runs at app start): try again
            // shortly rather than lose the reconciliation.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(200))
                self?.reconnectTasks()
            }
            return
        }
        let plan = DownloadRelaunchReconciler.plan(
            records: records.map {
                DownloadRelaunchReconciler.Record(
                    recordID: $0.recordID,
                    status: $0.status,
                    errorMessage: $0.errorMessage,
                    hasRetryEntry: retryStore.entry(itemId: $0.itemId, serverID: $0.serverID) != nil
                )
            },
            tasks: tasks.map {
                DownloadRelaunchReconciler.SessionTask(
                    taskIdentifier: $0.taskIdentifier,
                    recordID: taskRecordID($0.taskIdentifier),
                    isLive: $0.state == .running || $0.state == .suspended,
                    bytesReceived: $0.countOfBytesReceived
                )
            },
            alreadyRecovered: []
        )

        for task in tasks where plan.cancel.contains(task.taskIdentifier) {
            forgetTask(task.taskIdentifier)
            task.cancel()
        }
        let recordsByID = Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
        for task in tasks {
            guard let recordID = taskRecordID(task.taskIdentifier),
                  plan.adopt[recordID] == task.taskIdentifier else { continue }
            // The task kept going while the app was gone: pick its byte
            // counts up rather than starting the row from "Preparing...".
            scheduledTasks[task.taskIdentifier] = ScheduledTask(
                recordID: recordID,
                host: Self.hostKey(for: task.originalRequest?.url)
            )
            if task.countOfBytesReceived > 0 {
                byteCounts[recordID] = (task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
            }
            if recordsByID[recordID]?.status != .queued {
                appliedSlots[recordID] = .downloading
            }
        }
        // Queue order: oldest first.
        let requeue = plan.requeue.compactMap { recordsByID[$0] }.sorted { $0.dateAdded < $1.dateAdded }
        for record in requeue {
            if record.status != .queued { setStatus(record, .queued) }
            var job = DownloadJob(record: record)
            // A record past Queued was handed over, so already checked.
            job.originalVerified = record.status != .queued
            addPending(job)
        }

        hasReconciled = true
        recomputeSchedule()
        publishProgress()
        recoverInterruptedFailures()
        evaluateRetries()
        handOffPending()
    }

    /// Failed downloads that only failed because the device slept, the app
    /// was suspended or the network dropped -- under builds that counted
    /// that as a failure ("Could not fetch item info") -- are queued again
    /// by themselves, once each.
    private func recoverInterruptedFailures() {
        guard let context = mainContext,
              let records = try? context.fetch(FetchDescriptor<DownloadedItem>()) else { return }
        let defaults = UserDefaults.standard
        let recovered = Set(defaults.stringArray(forKey: Self.recoveredKey) ?? [])
        let plan = DownloadRelaunchReconciler.plan(
            records: records.map {
                DownloadRelaunchReconciler.Record(
                    recordID: $0.recordID,
                    status: $0.status,
                    errorMessage: $0.errorMessage,
                    hasRetryEntry: retryStore.entry(itemId: $0.itemId, serverID: $0.serverID) != nil
                )
            },
            tasks: [],
            alreadyRecovered: recovered
        )
        // Remember only records that still exist, so the list can't grow forever.
        let existing = Set(records.map(\.recordID))
        defaults.set(Array(recovered.intersection(existing).union(plan.recover)), forKey: Self.recoveredKey)
        let byID = Dictionary(records.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
        for recordID in plan.recover {
            guard let record = byID[recordID] else { continue }
            retryStore.clear(itemId: record.itemId, serverID: record.serverID)
            requeueFromScratch(record)
        }
    }

    func restartAllFailed() async {
        guard let context = mainContext else { return }
        let descriptor = FetchDescriptor<DownloadedItem>()
        guard let items = try? context.fetch(descriptor) else { return }

        let failedItems = items.filter { $0.status == .failed }
        for item in failedItems {
            await retryDownload(itemId: item.itemId, serverID: item.serverID)
        }
    }

    /// Artwork and subtitles for a download just handed over. Queued one
    /// download after another (a season queued at once would otherwise
    /// fire every request together), on the foreground API session --
    /// backfillSubtitles repairs whatever the app's suspension cuts off.
    private func fetchAssets(for job: DownloadJob, server: ServerConfig, token: String) {
        let itemId = job.itemId
        let previous = assetChain
        let task = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, let self else { return }
            async let poster: Void = self.downloadImage(ImageDownload(
                url: DownloadURLBuilder.posterURL(itemId: itemId, serverURL: server.url),
                token: token,
                destination: DownloadFileManager.posterPath(for: itemId, serverID: server.id),
                itemID: itemId,
                keyPath: "posterFileName",
                fileName: "poster.jpg"
            ))
            async let backdrop: Void = self.downloadImage(ImageDownload(
                url: DownloadURLBuilder.backdropURL(itemId: itemId, serverURL: server.url),
                token: token,
                destination: DownloadFileManager.backdropPath(for: itemId, serverID: server.id),
                itemID: itemId,
                keyPath: "backdropFileName",
                fileName: "backdrop.jpg"
            ))
            async let seriesPoster: Void = self.downloadSeriesPoster(for: job, server: server, token: token)
            async let subtitles: Void = self.downloadSubtitles(
                itemId: itemId,
                itemType: job.itemType,
                server: server,
                token: token
            )
            _ = await (poster, backdrop, seriesPoster, subtitles)
        }
        assetChain = task
        pendingAssetTasks[downloadKey(itemId: itemId, serverID: server.id)] = [task]
    }

    /// For episodes, the series poster too, for offline browsing.
    private func downloadSeriesPoster(for job: DownloadJob, server: ServerConfig, token: String) async {
        guard job.itemType == .episode, let seriesId = job.seriesId else { return }
        let destination = DownloadFileManager.itemDirectory(for: job.itemId, serverID: server.id)
            .appendingPathComponent("series_poster.jpg")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        await downloadImage(ImageDownload(
            url: DownloadURLBuilder.posterURL(itemId: seriesId, serverURL: server.url),
            token: token,
            destination: destination,
            itemID: job.itemId,
            keyPath: "",
            fileName: ""
        ))
    }

    private func downloadImage(_ asset: ImageDownload) async {
        guard let url = asset.url,
              let request = DownloadURLBuilder.authorizedRequest(for: url, accessToken: asset.token) else { return }
        do {
            try await DownloadAssetFetcher.live().fetch(request, to: asset.destination)
            if asset.keyPath == "posterFileName" {
                persistence.updatePosterFileName(itemId: asset.itemID, fileName: asset.fileName)
            } else if asset.keyPath == "backdropFileName" {
                persistence.updateBackdropFileName(itemId: asset.itemID, fileName: asset.fileName)
            }
        } catch {
            // Best-effort (images are not critical), but never silent: a trust
            // or proxy failure here used to leave every download posterless
            // with nothing in the log.
            logger.error(
                "Download artwork \(asset.keyPath, privacy: .public) failed for item \(asset.itemID, privacy: .public): \(DownloadAssetFetcher.logDescription(of: error), privacy: .public)"
            )
        }
    }

    private func downloadSubtitles(itemId: String, itemType: ItemType?, server: ServerConfig, token: String) async {
        // Runs on the foreground API session, not the background one: it dies the
        // moment iOS suspends the app. A download queued before the screen
        // locks used to finish its video with no subtitles at all -- the
        // player then showed a subtitle button with nothing in it. Ask for
        // time to finish; backfillSubtitles repairs anything that still misses.
        let backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "download-subtitles")
        defer {
            if backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(backgroundTask) }
        }
        _ = await fetchSubtitles(itemId: itemId, itemType: itemType, server: server, token: token, skipping: [])
    }

    /// The item's media source from playback info. For a download in flight
    /// its bitrates also feed the size estimate (see noteSource).
    private func mediaSource(itemId: String, itemType: ItemType?, server: ServerConfig) async -> MediaSourceInfo? {
        guard let client = try? await client(for: server.id),
              let playbackInfo = try? await client.getPlaybackInfo(
                  itemId: itemId,
                  itemType: itemType,
                  engine: .avFoundation,
                  maxBitrate: nil
              ),
              let mediaSource = playbackInfo.mediaSources?.first else {
            return nil
        }
        let key = downloadKey(itemId: itemId, serverID: server.id)
        if pendingProgress[key] != nil {
            noteSource(mediaSource, for: key)
        }
        return mediaSource
    }

    /// Downloads the item's subtitle tracks, except `skipping` (stream indexes
    /// already on disk). Returns what it wrote, or nil if the track list could
    /// not be fetched or any track failed -- so a caller can try again later.
    private func fetchSubtitles(
        itemId: String,
        itemType: ItemType?,
        server: ServerConfig,
        token: String,
        skipping: Set<Int>
    ) async -> [OfflineSubtitle]? {
        guard let mediaSource = await mediaSource(itemId: itemId, itemType: itemType, server: server) else {
            return nil
        }
        try? DownloadFileManager.createSubtitlesDirectory(for: itemId, serverID: server.id)

        var written: [OfflineSubtitle] = []
        var complete = true
        let fetcher = await DownloadAssetFetcher.live()
        for stream in mediaSource.subtitleStreams {
            guard let index = stream.index, !skipping.contains(index),
                  let language = stream.language ?? stream.displayTitle else {
                continue
            }

            guard let url = DownloadURLBuilder.subtitleURL(
                      itemId: itemId,
                      subtitleIndex: index,
                      serverURL: server.url
                  ),
                  let request = DownloadURLBuilder.authorizedRequest(for: url, accessToken: token) else {
                continue
            }

            let fileName = "\(index)_\(language).vtt"
            let destination = DownloadFileManager.subtitlePath(
                for: itemId,
                index: index,
                language: language,
                serverID: server.id
            )
            let displayTitle = stream.displayTitle ?? language

            do {
                try await fetcher.fetch(request, to: destination)
                persistence.addSubtitle(
                    itemId: itemId,
                    serverID: server.id,
                    language: language,
                    displayTitle: displayTitle,
                    subtitleIndex: index,
                    fileName: fileName
                )
                written.append(OfflineSubtitle(
                    index: index,
                    language: language,
                    displayTitle: displayTitle,
                    fileURL: destination
                ))
            } catch DownloadAssetFetcher.FetchError.badStatus(let status) {
                // An image-based track (PGS) has no VTT form: the server
                // answers 500, and saving that body gave a track with no cues.
                // Retrying will not change that, so it does not mark the set
                // incomplete.
                logger.info(
                    "Subtitle \(index, privacy: .public) for item \(itemId, privacy: .public) unavailable as VTT (HTTP \(status, privacy: .public))"
                )
            } catch {
                logger.error(
                    "Subtitle \(index, privacy: .public) download failed for item \(itemId, privacy: .public): \(DownloadAssetFetcher.logDescription(of: error), privacy: .public)"
                )
                complete = false
            }
        }
        return complete ? written : nil
    }

    /// Fetches the subtitle files a finished download is missing -- those
    /// lost when the app was suspended mid-fetch (see downloadSubtitles).
    /// Checks each download once per launch once it has everything; returns
    /// the item's full subtitle list when anything new arrived, else nil.
    func backfillSubtitles(itemId: String, serverID: String?) async -> [OfflineSubtitle]? {
        guard let record = downloadStatus(for: itemId, serverID: serverID), record.isComplete else { return nil }
        let key = downloadKey(itemId: itemId, serverID: record.serverID)
        guard !subtitlesVerified.contains(key),
              let context = serverContext(for: record.serverID) else { return nil }

        let existing = offlineSubtitles(for: itemId, serverID: record.serverID)
        guard let added = await fetchSubtitles(
            itemId: itemId,
            itemType: ItemType(rawValue: record.itemTypeRaw),
            server: context.server,
            token: context.token,
            skipping: Set(existing.map(\.index))
        ) else { return nil }

        subtitlesVerified.insert(key)
        guard !added.isEmpty else { return nil }
        return (existing + added).sorted { $0.index < $1.index }
    }

    /// Runs backfillSubtitles over every finished download, one at a time.
    func backfillAllSubtitles() async {
        guard let context = mainContext,
              let items = try? context.fetch(FetchDescriptor<DownloadedItem>()) else { return }
        for item in items where item.isComplete {
            _ = await backfillSubtitles(itemId: item.itemId, serverID: item.serverID)
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension DownloadManager: URLSessionDownloadDelegate {
    // Background URLSession requires the file move and state cleanup to remain
    // in one synchronous callback before Apple's temporary file is removed.
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskId = downloadTask.taskIdentifier
        let ext = downloadTask.response?.suggestedFilename?.components(separatedBy: ".").last ?? "mp4"

        // MUST move file synchronously — temp file at `location` is deleted when this callback returns
        let itemId: String? = UserDefaults.standard.dictionary(forKey: Self.taskMapKey)?[String(taskId)] as? String
        guard let itemId else { return }
        let serverID: String? = UserDefaults.standard.dictionary(forKey: Self.taskServerMapKey)?[String(taskId)] as? String

        // A background download task reports HTTP 4xx/5xx here (not as a
        // transport error), with the error page as the "downloaded" body.
        // Without this guard we'd move that page to video.mp4 and mark the
        // item COMPLETED — a broken file masquerading as a finished download.
        if let http = downloadTask.response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            Task { @MainActor in
                self.markFailed(
                    itemId: itemId,
                    serverID: serverID,
                    message: "Server returned HTTP \(http.statusCode)",
                    kind: DownloadRetryPolicy.classify(httpStatusCode: http.statusCode)
                )
                let key = self.downloadKey(itemId: itemId, serverID: serverID)
                self.clearProgress(for: key)
                self.appliedSlots.removeValue(forKey: key)
                self.forgetTask(taskId)
                self.recomputeSchedule()
            }
            return
        }

        let destination = DownloadFileManager.videoPath(for: itemId, container: ext, serverID: serverID)
        let moveError: Error?
        do {
            try DownloadFileManager.moveFile(from: location, to: destination)
            moveError = nil
        } catch {
            moveError = error
        }

        Task { @MainActor in
            if let moveError {
                self.markFailed(
                    itemId: itemId,
                    serverID: serverID,
                    message: "File move failed: \(moveError.localizedDescription)",
                    kind: DownloadRetryPolicy.classify(error: moveError)
                )
            } else {
                self.retryStore.clear(itemId: itemId, serverID: serverID)
                self.persistence.markCompleted(
                    itemId: itemId,
                    serverID: serverID,
                    videoFileName: "video.\(ext)",
                    totalBytes: DownloadFileManager.itemSize(for: itemId, serverID: serverID)
                )
                NotificationCenter.default.post(name: .downloadDidComplete, object: nil)
            }

            let key = self.downloadKey(itemId: itemId, serverID: serverID)
            self.clearProgress(for: key)
            self.appliedSlots.removeValue(forKey: key)
            self.forgetTask(taskId)
            if moveError == nil {
                self.forgetEstimate(for: key)
                // A completion delivered after a relaunch may find the
                // download already handed over again: drop the duplicate.
                self.removePending(key)
                await self.cancelTasks(for: key)
            }
            self.recomputeSchedule()
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskId = downloadTask.taskIdentifier
        // totalBytesExpectedToWrite is -1 for transcoded content (unknown size)
        let progress = totalBytesExpectedToWrite > 0
            ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            : -1 // negative signals unknown total

        Task { @MainActor in
            guard let itemId = self.taskIdMap[self.taskKey(taskId)] else { return }
            let serverID = self.taskServerMap[self.taskKey(taskId)]
            let key = self.downloadKey(itemId: itemId, serverID: serverID)

            // Update in-memory progress (published on timer)
            let firstBytes = (self.byteCounts[key]?.written ?? 0) <= 0 && totalBytesWritten > 0
            self.pendingProgress[key] = progress
            self.byteCounts[key] = (totalBytesWritten, totalBytesExpectedToWrite)

            // The session started it: Queued/Preparing becomes Downloading.
            if firstBytes {
                self.recomputeSchedule()
            }

            // Throttle SwiftData writes to every 5s per item. The saved
            // fraction is the shown one (estimated when there is no length).
            let now = Date()
            let lastSave = self.lastProgressSave[key] ?? .distantPast
            if now.timeIntervalSince(lastSave) >= 5 {
                self.lastProgressSave[key] = now
                self.persistence.updateProgress(
                    itemId: itemId,
                    serverID: serverID,
                    progress: self.progressDetail(for: key).display.fraction ?? progress,
                    downloadedBytes: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite
                )
            }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let taskId = task.taskIdentifier

        Task { @MainActor in
            guard let itemId = self.taskIdMap[self.taskKey(taskId)] else { return }
            let serverID = self.taskServerMap[self.taskKey(taskId)]
            let key = self.downloadKey(itemId: itemId, serverID: serverID)
            let end = DownloadTaskEnd.resolve(
                error: error,
                appIsActive: UIApplication.shared.applicationState == .active,
                networkAllowsDownloads: DownloadNetworkPolicy.canDownloadNow(
                    allowCellular: DownloadNetworkPolicy.allowsCellular,
                    network: .current
                )
            )
            switch end {
            case .ignore, .requeue:
                // The app forgets a task before it cancels one, so a
                // cancellation still mapped here wasn't the app's: requeue it.
                self.logger.info(
                    "Download \(itemId, privacy: .public) interrupted (\((error as NSError).code, privacy: .public)); queued again"
                )
                self.forgetTask(taskId)
                self.requeueInterrupted(itemId: itemId, serverID: serverID)
            case .fail(let kind):
                self.markFailed(itemId: itemId, serverID: serverID, message: error.localizedDescription, kind: kind)
                self.clearProgress(for: key)
                self.appliedSlots.removeValue(forKey: key)
                self.forgetTask(taskId)
            }
            self.recomputeSchedule()
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // Nothing to start: every queued download already has its task.
        Task { @MainActor in
            backgroundCompletionHandler?()
            backgroundCompletionHandler = nil
        }
    }
}
