import Foundation

/// The admin endpoints the Server dashboard reads and the two actions it
/// takes, as a protocol so its rules are testable without a server (the same
/// seam `ChannelManagementClient` uses).
protocol ServerDashboardClient: Sendable {
    func getActiveSessions() async throws -> [DashboardSession]
    func getActivityLog(limit: Int) async throws -> [ActivityLogEntry]
    func getScheduledTasks() async throws -> [ScheduledTaskInfo]
    func getDashboardSystemInfo() async throws -> DashboardSystemInfo
    /// Nil when the server has no storage endpoint; its rows are then dropped.
    func getStorageInfo() async throws -> SystemStorageInfo?
    func getEncodingOptions() async throws -> EncodingOptionsSummary
    func stopPlayback(sessionId: String) async throws
    func sendMessage(sessionId: String, text: String) async throws
}

extension JellyfinClient: ServerDashboardClient {}

extension SessionManager {
    /// Entry points to the Server dashboard render only when this is true.
    var canViewServerDashboard: Bool {
        ServerDashboardLogic.canShowDashboard(isAdministrator: isAdministrator, deniedByServer: serverDashboardDenied)
    }
}

enum ServerDashboardState: Equatable {
    case loading
    case loaded
    /// The server could not be reached; nothing stale is shown meanwhile.
    case failed
    /// The server refused admin data: everything is cleared and polling stops.
    case denied
}

/// The Server dashboard, shared by tvOS and iOS. Polls only while at least one
/// dashboard screen is visible and the app is in the foreground: sessions
/// every `sessionInterval`, activity and health every `slowInterval`.
@MainActor
final class ServerDashboardViewModel: ObservableObject {
    static let activityLimit = 15

    @Published private(set) var state: ServerDashboardState = .loading
    @Published private(set) var sessions: [DashboardSession] = []
    @Published private(set) var activity: [DashboardActivityRow] = []
    @Published private(set) var health: [DashboardHealthRow] = []
    @Published private(set) var systemInfo: DashboardSystemInfo?
    /// A Stop or Message that failed, for the screen to show.
    @Published var actionError: String?

    private let client: ServerDashboardClient
    private let sessionInterval: Duration
    private let slowInterval: Duration
    private let now: () -> Date
    private let onDenied: @MainActor () -> Void

    private var tasks: [ScheduledTaskInfo] = []
    private var storage: SystemStorageInfo?
    private var encoding: EncodingOptionsSummary?
    private var visibleScreens = 0
    private var sceneActive = true
    private var pollTask: Task<Void, Never>?

    init(
        client: ServerDashboardClient? = nil,
        sessionInterval: Duration = .seconds(7),
        slowInterval: Duration = .seconds(30),
        now: @escaping () -> Date = Date.init,
        onDenied: (@MainActor () -> Void)? = nil
    ) {
        self.client = client ?? JellyfinClient.shared
        self.sessionInterval = sessionInterval
        self.slowInterval = slowInterval
        self.now = now
        self.onDenied = onDenied ?? { SessionManager.shared.noteServerDashboardDenied() }
    }

    // MARK: - Summary

    var convertingCount: Int {
        sessions.filter { ServerDashboardLogic.playMode($0.transcodingInfo) != .directPlay }.count
    }

    var totalBitrate: Int { ServerDashboardLogic.totalBitrate(sessions) }

    var attention: [DashboardAttentionRow] {
        ServerDashboardLogic.attention(activity: activity, health: health)
    }

    /// "JellyPal · Jellyfin 12.2.0"
    var serverLine: String {
        [systemInfo?.serverName, systemInfo?.version.map { "Jellyfin \($0)" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    // MARK: - Visibility

    var isPolling: Bool { pollTask != nil }

    /// A dashboard screen appeared. Each screen that attaches must detach.
    func attach() {
        visibleScreens += 1
        updatePolling()
    }

    func detach() {
        visibleScreens = max(0, visibleScreens - 1)
        updatePolling()
    }

    func setSceneActive(_ active: Bool) {
        sceneActive = active
        updatePolling()
    }

    private func updatePolling() {
        let shouldPoll = visibleScreens > 0 && sceneActive && state != .denied
        if shouldPoll, pollTask == nil {
            pollTask = Task { [weak self] in await self?.pollLoop() }
        } else if !shouldPoll {
            pollTask?.cancel()
            pollTask = nil
        }
    }

    private func pollLoop() async {
        let clock = ContinuousClock()
        var lastFullRefresh: ContinuousClock.Instant?
        while !Task.isCancelled {
            if let last = lastFullRefresh, clock.now - last < slowInterval {
                await refreshSessions()
            } else {
                await refreshAll()
                lastFullRefresh = clock.now
            }
            try? await Task.sleep(for: sessionInterval)
        }
    }

    // MARK: - Loading

    func refreshAll() async {
        async let sessions = client.getActiveSessions()
        async let activity = client.getActivityLog(limit: Self.activityLimit)
        async let tasks = client.getScheduledTasks()
        async let info = client.getDashboardSystemInfo()
        async let storage = client.getStorageInfo()
        async let encoding = client.getEncodingOptions()
        do {
            let loaded = try await (sessions, activity, tasks, info)
            // Storage and encoding only colour the health panel; a failure
            // there drops their rows rather than the whole screen.
            let storageInfo = (try? await storage).flatMap { $0 }
            let encodingInfo = try? await encoding
            guard !Task.isCancelled, state != .denied else { return }
            self.tasks = loaded.2
            self.storage = storageInfo
            self.encoding = encodingInfo
            self.systemInfo = loaded.3
            self.activity = loaded.1.map { ServerDashboardLogic.activityRow($0, now: now()) }
            apply(sessions: loaded.0)
            state = .loaded
        } catch {
            handle(error)
        }
    }

    func refreshSessions() async {
        do {
            let latest = try await client.getActiveSessions()
            guard !Task.isCancelled, state != .denied else { return }
            apply(sessions: latest)
            if state != .loaded { await refreshAll() }
        } catch {
            handle(error)
        }
    }

    private func apply(sessions latest: [DashboardSession]) {
        sessions = latest
            .filter { $0.nowPlayingItem != nil }
            .sorted { ($0.userName ?? "", $0.deviceName ?? "") < ($1.userName ?? "", $1.deviceName ?? "") }
        health = ServerDashboardLogic.healthRows(tasks: tasks, storage: storage, encoding: encoding, sessions: sessions, now: now())
    }

    private func handle(_ error: Error) {
        if error is CancellationError || Task.isCancelled { return }
        if ServerDashboardLogic.isAccessDenied(error) {
            deny()
            return
        }
        guard state != .denied else { return }
        clearData()
        state = .failed
    }

    private func deny() {
        clearData()
        state = .denied
        pollTask?.cancel()
        pollTask = nil
        onDenied()
    }

    private func clearData() {
        sessions = []
        activity = []
        health = []
        systemInfo = nil
        tasks = []
        storage = nil
        encoding = nil
    }

    // MARK: - Actions

    /// Stops a stream (after the screen's confirmation). Only remote-controllable
    /// sessions offer it.
    func stop(_ session: DashboardSession) async {
        guard session.supportsRemoteControl else { return }
        do {
            try await client.stopPlayback(sessionId: session.id)
            await refreshSessions()
        } catch {
            if ServerDashboardLogic.isAccessDenied(error) { deny() } else { actionError = "Couldn't stop the stream." }
        }
    }

    /// Shows a short message on the viewer's screen. Returns whether it was sent.
    @discardableResult
    func message(_ session: DashboardSession, text: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard session.supportsRemoteControl, !trimmed.isEmpty else { return false }
        do {
            try await client.sendMessage(sessionId: session.id, text: String(trimmed.prefix(Self.messageLimit)))
            return true
        } catch {
            if ServerDashboardLogic.isAccessDenied(error) { deny() } else { actionError = "Couldn't send the message." }
            return false
        }
    }

    static let messageLimit = 200
}
