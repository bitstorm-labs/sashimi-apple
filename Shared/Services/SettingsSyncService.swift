import Combine
import Foundation
import os
import UIKit

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "SettingsSync")

/// A device's Home row layout, in shared ids. Each app target supplies one
/// (tvOS `HomeScreenSettings`, iPhone/iPad/Mac `HomeRowSettings`).
@MainActor
protocol SettingsSyncLayoutSource: AnyObject {
    /// Where this layout's stamp is kept. Per server where the rows are.
    var stampKey: String { get }
    /// Whether the layout was ever saved on this device (seeding).
    var isExplicit: Bool { get }
    /// The rows now, in order; nil while the device doesn't know them yet.
    func currentLayout() -> [SettingsSync.LayoutEntry]?
    /// Reorders and switches this device's rows to `layout` and saves them.
    func apply(_ layout: [SettingsSync.LayoutEntry])
    /// Fires after the rows change (delivered later on the main queue).
    var changes: AnyPublisher<Void, Never> { get }
}

/// One scalar setting: its shared key and where this device keeps it.
struct SettingsSyncBinding {
    let key: SettingsSync.Key
    let localKey: String
    let defaultValue: SettingsSync.Value
    /// Runs after a remote value is written, for stores that cache it.
    var didApply: (@MainActor () -> Void)?

    func read(_ defaults: UserDefaults) -> SettingsSync.Value {
        switch defaultValue {
        case .bool(let fallback): return .bool(defaults.object(forKey: localKey) as? Bool ?? fallback)
        case .int(let fallback): return .int(defaults.object(forKey: localKey) as? Int ?? fallback)
        case .string(let fallback): return .string(defaults.string(forKey: localKey) ?? fallback)
        case .layout: return defaultValue
        }
    }

    func write(_ value: SettingsSync.Value, to defaults: UserDefaults) {
        switch value {
        case .bool(let bool): defaults.set(bool, forKey: localKey)
        case .int(let int): defaults.set(int, forKey: localKey)
        case .string(let string): defaults.set(string, forKey: localKey)
        case .layout: break
        }
    }

    func isExplicit(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: localKey) != nil
    }

    private static func binding(_ name: String, local: String? = nil, _ fallback: SettingsSync.Value,
                                didApply: (@MainActor () -> Void)? = nil) -> SettingsSyncBinding {
        guard let key = SettingsSync.key(name) else { preconditionFailure("unknown sync key \(name)") }
        return SettingsSyncBinding(key: key, localKey: local ?? name, defaultValue: fallback, didApply: didApply)
    }

    /// This platform's scalar settings. 24-Hour Time syncs on tvOS only:
    /// iPhone, iPad and Mac follow the system clock format.
    static var platform: [SettingsSyncBinding] {
        var bindings: [SettingsSyncBinding] = [
            binding("autoPlayNextEpisode", .bool(true)),
            binding("autoSkipIntro", .bool(false)),
            binding("autoSkipCredits", .bool(false)),
            binding("resumeThresholdSeconds", .int(30)),
            binding("forceDirectPlay", .bool(false)),
            binding("subtitlesEnabled", .bool(false)),
            binding("preferredAudioLanguage", .string("")),
            binding("preferredSubtitleLanguage", .string("")),
            binding("tvShuffleMode", .string(PlaybackSettings.defaultTVShuffleMode.rawValue)),
            binding("defaultViewMode", local: VideoViewModeStore.defaultModeKey, .string(VideoViewMode.normal.rawValue)) {
                VideoViewModeStore.shared.reloadDefault()
            },
            binding("showQualityBadges", .bool(true)),
            binding("showReviewRatings", .bool(true)),
            binding("useEpisodeRatings", .bool(false)),
        ]
        #if os(tvOS)
        bindings.append(binding("use24HourTime", .bool(false)))
        #endif
        return bindings
    }
}

/// Keeps this device's synced settings in step with the user's
/// `sashimi-settings` entry (WORK-106). Records a stamp whenever a synced
/// setting changes here, however it changed; reconciles on launch, on return
/// to the foreground, on a server or user switch, when sync is turned on and
/// shortly after a local change. Makes no network call while sync is off.
@MainActor
final class SettingsSyncService {
    static let shared = SettingsSyncService()

    static let enabledKey = "settingsSyncEnabled"
    static let toggleFooter = "Playback, display and Home row choices follow you to every Sashimi app signed in as you on this server. Turn off to keep this device's settings to itself."
    static let stampsKey = "settingsSyncStamps"
    static let snapshotKey = "settingsSyncSnapshot"
    static let layoutCacheKey = "settingsSyncLayoutCache"

    var layoutSource: SettingsSyncLayoutSource? {
        didSet { observeLayout() }
    }

    private let defaults: UserDefaults
    private let client: () -> JellyfinClient
    private let now: () -> Int64
    private let bindings: [SettingsSyncBinding]
    private let pushDelay: Duration
    private var started = false
    /// Set while remote values are written: each write posts a change
    /// notification, and between the writes the snapshot and the settings
    /// briefly disagree. None of that is a local change.
    private var isApplying = false
    private var lastEnabled: Bool
    private var defaultsObserver: NSObjectProtocol?
    private var layoutObserver: AnyCancellable?
    private var appObservers: [AnyCancellable] = []
    private var inFlight: Task<Void, Never>?
    private var pendingPush: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         client: @escaping () -> JellyfinClient = { JellyfinClient.shared },
         now: @escaping () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) },
         bindings: [SettingsSyncBinding] = SettingsSyncBinding.platform,
         pushDelay: Duration = .seconds(1)) {
        self.defaults = defaults
        self.client = client
        self.now = now
        self.bindings = bindings
        self.pushDelay = pushDelay
        self.lastEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var isEnabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    /// Stamps by key, as stored.
    var stamps: [String: Int64] {
        get { (defaults.dictionary(forKey: Self.stampsKey) ?? [:]).compactMapValues { ($0 as? NSNumber)?.int64Value } }
        set { defaults.set(newValue.mapValues { NSNumber(value: $0) }, forKey: Self.stampsKey) }
    }

    private var snapshot: [String: String] {
        get { defaults.dictionary(forKey: Self.snapshotKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.snapshotKey) }
    }

    private var layoutCache: [String: String] {
        get { defaults.dictionary(forKey: Self.layoutCacheKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.layoutCacheKey) }
    }

    /// Seeds stamps for settings seen for the first time and starts watching
    /// for changes. Call once at launch, before any setting can change.
    func start() {
        guard !started else { return }
        started = true
        noteLocalChanges()
        layoutChanged()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteLocalChanges() }
        }
    }

    /// The app's entry point, from its `init` (before anything can change a
    /// setting, so the first change is stamped rather than seeded). Reconciles
    /// on every signed-in session (launch, server or user switch) and on each
    /// return to the foreground.
    func startApp(layout: SettingsSyncLayoutSource) {
        layoutSource = layout
        start()
        let session = SessionManager.shared
        appObservers = [
            session.objectWillChange
                .receive(on: DispatchQueue.main)
                .map { session.isAuthenticated ? "\(session.activeSessionIdentity):\(session.currentUser?.id ?? "")" : nil }
                .removeDuplicates()
                .sink { [weak self] identity in
                    guard identity != nil else { return }
                    Task { await self?.reconcile() }
                },
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                .sink { [weak self] _ in Task { await self?.reconcile() } },
        ]
    }

    // MARK: Local changes

    /// Compares every scalar setting with its last known value. A changed one
    /// gets `stamp = now`; one never seen before is seeded instead.
    func noteLocalChanges() {
        guard !isApplying else { return }
        var snapshot = self.snapshot
        var stamps = self.stamps
        var changed = false
        for binding in bindings {
            let encoded = SettingsSync.encodeValue(binding.read(defaults))
            guard let previous = snapshot[binding.key.name] else {
                // First sighting (an upgrade, or a key added later): an
                // explicitly set value gets the seed stamp, a default none.
                if stamps[binding.key.name] == nil, binding.isExplicit(defaults) {
                    stamps[binding.key.name] = SettingsSync.seedStamp
                }
                snapshot[binding.key.name] = encoded
                continue
            }
            if previous != encoded {
                snapshot[binding.key.name] = encoded
                stamps[binding.key.name] = now()
                changed = true
            }
        }
        if snapshot != self.snapshot { self.snapshot = snapshot }
        if stamps != self.stamps { self.stamps = stamps }

        let enabled = isEnabled
        let turnedOn = enabled && !lastEnabled
        lastEnabled = enabled
        if turnedOn {
            Task { await reconcile() }
        } else if changed {
            schedulePush()
        }
    }

    private func observeLayout() {
        layoutObserver = layoutSource?.changes
            .sink { [weak self] in self?.layoutChanged() }
        if started { layoutChanged() }
    }

    /// The rows changed. A move or a switch is the user's edit (stamp = now);
    /// rows arriving on their own (a new library) are placed by the last
    /// synced layout instead.
    func layoutChanged() {
        guard let source = layoutSource, let current = source.currentLayout() else { return }
        let key = source.stampKey
        let encoded = SettingsSync.encodeValue(.layout(current))
        guard let previousEncoded = snapshot[key] else {
            if stamps[key] == nil, source.isExplicit { stamps[key] = SettingsSync.seedStamp }
            snapshot[key] = encoded
            // The rows just became known (a fresh tvOS install, a server
            // switch): a remote layout may be waiting for them.
            schedulePush()
            return
        }
        guard previousEncoded != encoded else { return }
        snapshot[key] = encoded
        guard case .layout(let previous)? = SettingsSync.decodeValue(previousEncoded, kind: .layout) else { return }
        if SettingsSync.isLayoutEdit(from: previous, to: current) {
            stamps[key] = now()
            schedulePush()
            return
        }
        let grew = !Set(current.map(\.id)).isSubset(of: previous.map(\.id))
        guard grew, let cached = layoutCache[key],
              case .valid(let synced) = SettingsSync.decode(cached, kind: .layout),
              synced.t == stamps[key], case .layout(let layout) = synced.value else { return }
        let placed = SettingsSync.applyLayout(local: current, remote: layout)
        guard placed != current else { return }
        snapshot[key] = SettingsSync.encodeValue(.layout(placed))
        source.apply(placed)
    }

    private func schedulePush() {
        guard isEnabled else { return }
        pendingPush?.cancel()
        let delay = pushDelay
        pendingPush = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.reconcile()
        }
    }

    /// Waits for a scheduled push to finish (tests).
    func waitForPendingWork() async {
        await pendingPush?.value
        await inFlight?.value
    }

    // MARK: Reconcile

    /// Reads the entry once, applies newer remote values, and writes newer
    /// local ones in one POST. Calls run one at a time.
    func reconcile() async {
        let previous = inFlight
        let task = Task { [weak self] in
            await previous?.value
            await self?.performReconcile()
        }
        inFlight = task
        await task.value
    }

    private func performReconcile() async {
        guard isEnabled else { return }
        noteLocalChanges()
        let client = client()
        let stored: Data
        do {
            stored = try await client.getDisplayPreferences(id: SettingsSync.preferencesId, client: SettingsSync.preferencesClient)
        } catch {
            if case JellyfinError.notConfigured = error { return }
            logger.error("Settings sync read failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard isEnabled else { return }
        let remote = SettingsSync.customPrefs(in: stored)
        var writes: [String: String] = [:]
        reconcileScalars(remote: remote, writes: &writes)
        reconcileLayout(remote: remote, writes: &writes)
        guard !writes.isEmpty else { return }
        let body = SettingsSync.displayPreferencesBody(stored: stored, writes: writes)
        do {
            try await client.saveDisplayPreferences(id: SettingsSync.preferencesId, client: SettingsSync.preferencesClient, body: body)
        } catch {
            logger.error("Settings sync write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func reconcileScalars(remote: [String: String], writes: inout [String: String]) {
        var stamps = self.stamps
        var snapshot = self.snapshot
        var applied: [(SettingsSyncBinding, SettingsSync.Value)] = []
        for binding in bindings {
            let name = binding.key.name
            let local = binding.read(defaults)
            let decision = SettingsSync.decide(kind: binding.key.kind, localValue: local, localStamp: stamps[name],
                                               remote: SettingsSync.decode(remote[name], kind: binding.key.kind))
            switch decision {
            case .apply(let stamped):
                // Recorded before the write, so the change notification the
                // write posts is not taken for a local change.
                stamps[name] = stamped.t
                snapshot[name] = SettingsSync.encodeValue(stamped.value)
                applied.append((binding, stamped.value))
            case .write(let t):
                writes[name] = SettingsSync.encode(.init(value: local, t: t))
            case .none:
                break
            }
        }
        isApplying = true
        self.stamps = stamps
        self.snapshot = snapshot
        for (binding, value) in applied {
            binding.write(value, to: defaults)
        }
        isApplying = false
        applied.forEach { $0.0.didApply?() }
    }

    private func reconcileLayout(remote: [String: String], writes: inout [String: String]) {
        guard let source = layoutSource, let local = source.currentLayout() else { return }
        let key = source.stampKey
        let decoded = SettingsSync.decode(remote[SettingsSync.homeRowsKey], kind: .layout)
        switch SettingsSync.decide(kind: .layout, localValue: .layout(local), localStamp: stamps[key], remote: decoded) {
        case .apply(let stamped):
            guard case .layout(let layout) = stamped.value else { return }
            let applied = SettingsSync.applyLayout(local: local, remote: layout)
            stamps[key] = stamped.t
            snapshot[key] = SettingsSync.encodeValue(.layout(applied))
            layoutCache[key] = SettingsSync.encode(stamped)
            if applied != local { source.apply(applied) }
        case .write(let t):
            var remoteLayout: [SettingsSync.LayoutEntry]?
            if case .valid(let stamped) = decoded, case .layout(let layout) = stamped.value { remoteLayout = layout }
            let written = SettingsSync.Stamped(value: .layout(SettingsSync.writeLayout(local: local, remote: remoteLayout)), t: t)
            let encoded = SettingsSync.encode(written)
            writes[SettingsSync.homeRowsKey] = encoded
            layoutCache[key] = encoded
        case .none:
            break
        }
    }
}
