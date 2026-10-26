import SwiftUI

// MARK: - Shared flow

/// The tail every bulk download action shares — the series page's Download
/// menu, an episode's download menu and an episode's context menu (#744):
/// pick the episodes, ask for a quality once, confirm big batches, then queue
/// them. Also turns "Keep next episodes downloaded" on, asking for a quality
/// when the show has no download to take it from.
@MainActor
final class BulkDownloadFlow: ObservableObject {
    struct PendingBatch {
        let quality: DownloadQuality
        let title: String
    }

    /// "Keep next N" waiting on a quality choice.
    struct PendingKeepNext {
        let count: Int
        let serverID: String
        let seriesId: String
    }

    var serverID: String?

    @Published var candidates: [BaseItemDto] = []
    /// What the user picked ("Download Series"), named in the quality dialog
    /// so a tap on the neighbouring entry shows before anything downloads.
    @Published var batchTitle = ""
    @Published var showingQuality = false
    @Published var pendingBatch: PendingBatch?
    @Published var pendingKeepNext: PendingKeepNext?
    @Published var notice: String?
    @Published var isLoading = false
    /// Fail-closed: Original is offered only once a sample episode is
    /// confirmed to direct-play here (series are uniformly encoded).
    @Published var originalAllowed = false

    private let downloadManager = DownloadManager.shared
    private let keepNextStore = KeepNextEpisodesStore.shared

    init(serverID: String? = nil) {
        self.serverID = serverID
    }

    var availableQualities: [DownloadQuality] {
        DownloadQuality.allCases.filter { $0 != .original || originalAllowed }
    }

    /// The download status of an item on this flow's server.
    func status(of itemId: String) -> DownloadStatus? {
        downloadManager.downloadStatus(for: itemId, serverID: serverID)?.status
    }

    /// Load the episodes, choose from them, then ask for a quality. `choose`
    /// returns what it selected and what of that still needs queueing.
    /// `originalSample`, when given, is checked for Original before the
    /// quality dialog (the episode menu has no page-wide check to rely on).
    func begin(
        title: String,
        unwatchedOnly: Bool,
        originalSample: BaseItemDto? = nil,
        load: @escaping () async -> [BaseItemDto]?,
        choose: @escaping ([BaseItemDto]) -> (selected: [BaseItemDto], pending: [BaseItemDto])
    ) {
        Task {
            isLoading = true
            defer { isLoading = false }
            guard let source = await load() else {
                notice = "Couldn't load this series' episodes. Try again."
                return
            }
            let (selected, pending) = choose(source)
            guard !pending.isEmpty else {
                notice = selected.isEmpty
                    ? "There are no \(unwatchedOnly ? "unwatched " : "")episodes to download."
                    : "Every episode is already downloaded or queued."
                return
            }
            candidates = pending
            batchTitle = title
            pendingKeepNext = nil
            if let originalSample { await refreshOriginalAllowed(sample: originalSample) }
            // Let a dismissing menu/alert finish before presenting the dialog.
            try? await Task.sleep(for: .milliseconds(300))
            showingQuality = true
        }
    }

    /// One of the series page's season/series scopes.
    func begin(_ scope: BulkDownloadScope, seasonEpisodes: [BaseItemDto], seriesId: String?) {
        begin(title: scope.dialogTitle, unwatchedOnly: scope.isUnwatchedOnly) {
            await BulkDownloadSource.episodes(for: scope, seasonEpisodes: seasonEpisodes, seriesId: seriesId)
        } choose: { [weak self] source in
            let selected = BulkDownloadPlanner.select(scope, from: source)
            let pending = BulkDownloadPlanner.pending(selected) { self?.status(of: $0) }
            return (selected, pending)
        }
    }

    /// One of an episode's scopes (#744), over the whole series.
    func begin(_ scope: EpisodeDownloadScope, for episode: BaseItemDto) {
        let unwatchedOnly: Bool
        if case .thisAndNext = scope { unwatchedOnly = false } else { unwatchedOnly = true }
        begin(title: scope.title, unwatchedOnly: unwatchedOnly, originalSample: episode) {
            guard let seriesId = episode.seriesId else { return nil }
            return try? await JellyfinClient.shared.getEpisodes(seriesId: seriesId)
        } choose: { [weak self] source in
            let status: (String) -> DownloadStatus? = { self?.status(of: $0) }
            let pending = EpisodeDownloadPlanner.select(scope, for: episode, seriesEpisodes: source, status: status)
            // "Selected" only decides the empty message: was anything in range?
            let selected = EpisodeDownloadPlanner.select(scope, for: episode, seriesEpisodes: source) { _ in nil }
            return (selected, pending)
        }
    }

    func chooseQuality(_ quality: DownloadQuality) {
        if let keepNext = pendingKeepNext {
            pendingKeepNext = nil
            applyKeepNext(keepNext.count, quality: quality, serverID: keepNext.serverID, seriesId: keepNext.seriesId)
            return
        }
        guard BulkDownloadPlanner.needsConfirmation(count: candidates.count) else {
            enqueue(quality)
            return
        }
        let title = BulkDownloadPlanner.confirmationTitle(
            count: candidates.count,
            estimatedBytes: BulkDownloadPlanner.estimatedBytes(for: candidates, quality: quality)
        )
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            pendingBatch = PendingBatch(quality: quality, title: title)
        }
    }

    func enqueue(_ quality: DownloadQuality) {
        downloadManager.downloadSeason(episodes: candidates, quality: quality, serverID: serverID)
        candidates = []
    }

    func cancel() {
        candidates = []
        pendingKeepNext = nil
    }

    // MARK: Keep next episodes

    /// Settings are per server; a nil serverID means the active one, as it
    /// does for the downloads this flow queues.
    var keepNextServerID: String? {
        serverID ?? SessionManager.shared.activeServerId
    }

    func keepNextCount(seriesId: String) -> Int {
        keepNextStore.count(serverID: keepNextServerID, seriesId: seriesId)
    }

    func keepNextMenuTitle(seriesId: String) -> String {
        let count = keepNextCount(seriesId: seriesId)
        return count > 0 ? "Keep Next Episodes Downloaded: \(count)" : "Keep Next Episodes Downloaded"
    }

    /// Changing the count or turning it off needs no quality. Turning it on
    /// takes the quality of the show's latest download, or asks for one.
    func setKeepNext(_ count: Int, seriesId: String) {
        guard let serverID = keepNextServerID else { return }
        if count == 0 || keepNextStore.setting(serverID: serverID, seriesId: seriesId) != nil {
            applyKeepNext(count, quality: nil, serverID: serverID, seriesId: seriesId)
        } else if let quality = downloadManager.latestQuality(seriesId: seriesId, serverID: serverID) {
            applyKeepNext(count, quality: quality, serverID: serverID, seriesId: seriesId)
        } else {
            candidates = []
            pendingKeepNext = PendingKeepNext(count: count, serverID: serverID, seriesId: seriesId)
            Task {
                // Let the dismissing menu finish before presenting the dialog.
                try? await Task.sleep(for: .milliseconds(300))
                showingQuality = true
            }
        }
    }

    private func applyKeepNext(_ count: Int, quality: DownloadQuality?, serverID: String, seriesId: String) {
        keepNextStore.set(count: count, quality: quality, serverID: serverID, seriesId: seriesId)
        if count > 0 {
            let waitsForWiFi = DownloadNetworkPolicy.waitReason(
                allowCellular: DownloadNetworkPolicy.allowsCellular,
                network: .current
            ) == .cellular
            downloadManager.toastMessage = "Keeping the next \(count == 1 ? "episode" : "\(count) episodes") downloaded"
                + (waitsForWiFi ? " on Wi-Fi" : "")
            KeepNextEpisodesService.shared.scheduleSync(after: .zero)
        }
    }

    // MARK: Original availability

    func refreshOriginalAllowed(sample: BaseItemDto?) async {
        originalAllowed = false
        guard NetworkMonitor.shared.isOnline, let sample else { return }
        do {
            let info = try await JellyfinClient.shared.getPlaybackInfo(
                itemId: sample.id, itemType: sample.type, engine: .avFoundation
            )
            originalAllowed = info.mediaSources?.first
                .map { DeviceMediaCompatibility.canRemuxForDownload($0) } ?? false
        } catch {
            originalAllowed = false
        }
    }
}

/// The quality dialog, big-batch confirmation and "nothing to download" alert
/// of a `BulkDownloadFlow`.
struct BulkDownloadDialogs: ViewModifier {
    @ObservedObject var flow: BulkDownloadFlow

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Select Quality", isPresented: $flow.showingQuality, titleVisibility: .visible) {
                ForEach(flow.availableQualities) { quality in
                    Button("\(quality.displayName) \u{2014} \(quality.subtitle)") { flow.chooseQuality(quality) }
                }
                Button("Cancel", role: .cancel) { flow.cancel() }
            } message: {
                if let keepNext = flow.pendingKeepNext {
                    Text("Keep the next \(keepNext.count == 1 ? "episode" : "\(keepNext.count) episodes") downloaded")
                } else {
                    Text(BulkDownloadPlanner.qualityMessage(title: flow.batchTitle, count: flow.candidates.count))
                }
            }
            .alert(
                flow.pendingBatch?.title ?? "",
                isPresented: isPresenting($flow.pendingBatch),
                presenting: flow.pendingBatch
            ) { batch in
                Button("Download") { flow.enqueue(batch.quality) }
                Button("Cancel", role: .cancel) { flow.cancel() }
            }
            .alert("Nothing to Download", isPresented: isPresenting($flow.notice)) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(flow.notice ?? "")
            }
    }

    private func isPresenting<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

extension View {
    func bulkDownloadDialogs(_ flow: BulkDownloadFlow) -> some View {
        modifier(BulkDownloadDialogs(flow: flow))
    }
}

/// "Keep Next Episodes Downloaded[: N]" with its 1 / 3 / 5 / Off picker.
struct KeepNextEpisodesMenu: View {
    @ObservedObject var flow: BulkDownloadFlow
    let seriesId: String

    @ObservedObject private var keepNextStore = KeepNextEpisodesStore.shared

    var body: some View {
        Menu {
            KeepNextEpisodesPicker(selection: flow.keepNextCount(seriesId: seriesId)) { count in
                flow.setKeepNext(count, seriesId: seriesId)
            }
        } label: {
            Label(flow.keepNextMenuTitle(seriesId: seriesId), systemImage: "arrow.triangle.2.circlepath")
        }
    }
}

// MARK: - Series page menu

/// The download menu on a series or season page: whole-series and
/// selected-season bulk actions (the season page shows only the season's).
struct BulkDownloadMenu: View {
    /// Episodes of the season currently shown on the page.
    let seasonEpisodes: [BaseItemDto]
    /// Section header for the season actions, e.g. "Season 2".
    var seasonName: String?
    /// The series to fetch every episode of for the series-wide actions.
    /// Nil hides "Download Unwatched" and "Download Series".
    var seriesId: String?
    var serverID: String?
    /// Icon-only label (iPhone) instead of an icon and `title` (iPad).
    var compact = false
    /// The label's text: "Download", or "Download Season" on a season page.
    var title = "Download"

    @StateObject private var flow = BulkDownloadFlow()
    @State private var showingNextN = false
    @State private var nextNInput = ""

    var body: some View {
        Menu {
            menuContent
        } label: {
            label
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .disabled(flow.isLoading)
        .onAppear { flow.serverID = serverID }
        .onChange(of: serverID) { _, newValue in flow.serverID = newValue }
        .task(id: seasonEpisodes.first?.id) { await flow.refreshOriginalAllowed(sample: seasonEpisodes.first) }
        .bulkDownloadDialogs(flow)
        .alert("Download Unwatched Episodes", isPresented: $showingNextN) {
            TextField("Number of episodes", text: $nextNInput)
                .keyboardType(.numberPad)
            Button("OK") {
                if let count = Int(nextNInput), count > 0 { begin(.nextUnwatched(count)) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("How many unwatched episodes would you like to download?")
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if let seriesId {
            Section("Series") {
                Button(BulkDownloadScope.seriesUnwatched.title) { begin(.seriesUnwatched) }
                Button(BulkDownloadScope.series.title) { begin(.series) }
            }
            if flow.keepNextServerID != nil {
                Section {
                    KeepNextEpisodesMenu(flow: flow, seriesId: seriesId)
                }
            }
        }
        if !seasonEpisodes.isEmpty {
            Section(seasonName ?? "Season") {
                Button(BulkDownloadScope.season.title) { begin(.season) }
                Button(BulkDownloadScope.seasonUnwatched.title) { begin(.seasonUnwatched) }
                Button(BulkDownloadScope.nextUnwatched(0).title) {
                    nextNInput = ""
                    showingNextN = true
                }
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if flow.isLoading {
            ProgressView()
                .scaleEffect(0.7)
        } else if compact {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 20))
        } else {
            Label(title, systemImage: "arrow.down.circle")
                .font(.system(size: 14, weight: .semibold))
        }
    }

    private func begin(_ scope: BulkDownloadScope) {
        flow.serverID = serverID
        flow.begin(scope, seasonEpisodes: seasonEpisodes, seriesId: seriesId)
    }
}

// MARK: - An episode's bulk entries

/// The bulk half of an episode's download menu (#744): "This and the Next…",
/// "Unwatched in Season X", "Unwatched in Series" and Keep Next. The caller
/// puts the single-episode action above it.
struct EpisodeBulkDownloadItems: View {
    let episode: BaseItemDto
    @ObservedObject var flow: BulkDownloadFlow

    var body: some View {
        Menu {
            ForEach(EpisodeDownloadPlanner.nextCounts, id: \.self) { count in
                Button(EpisodeDownloadPlanner.nextCountTitle(count)) {
                    flow.begin(.thisAndNext(count), for: episode)
                }
            }
        } label: {
            Label("This and the Next\u{2026}", systemImage: "arrow.down.to.line")
        }
        Divider()
        Button {
            flow.begin(.unwatchedInSeason, for: episode)
        } label: {
            Label(EpisodeDownloadPlanner.seasonTitle(episode), systemImage: "arrow.down.circle")
        }
        Button {
            flow.begin(.unwatchedInSeries, for: episode)
        } label: {
            Label("Unwatched in Series", systemImage: "arrow.down.circle")
        }
        if let seriesId = episode.seriesId, flow.keepNextServerID != nil {
            KeepNextEpisodesMenu(flow: flow, seriesId: seriesId)
        }
    }
}
