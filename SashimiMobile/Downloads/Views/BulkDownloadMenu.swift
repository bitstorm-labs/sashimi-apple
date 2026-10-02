import SwiftUI

/// The download menu on a series or season page: whole-series and
/// selected-season bulk actions. Picks the episodes, asks for a quality once,
/// confirms big batches, then queues them through DownloadManager.
struct BulkDownloadMenu: View {
    /// Episodes of the season currently shown on the page.
    let seasonEpisodes: [BaseItemDto]
    /// Section header for the season actions, e.g. "Season 2".
    var seasonName: String?
    /// The series to fetch every episode of for the series-wide actions.
    /// Nil hides "Download Unwatched" and "Download Series".
    var seriesId: String?
    var serverID: String?
    /// Icon-only label (iPhone) instead of an icon and "Download" (iPad).
    var compact = false

    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var candidates: [BaseItemDto] = []
    @State private var showingQuality = false
    @State private var pendingBatch: PendingBatch?
    @State private var showingNextN = false
    @State private var nextNInput = ""
    @State private var notice: String?
    @State private var isLoading = false
    // Fail-closed: Original is offered only once the season's first episode
    // is confirmed to direct-play here (series are uniformly encoded).
    @State private var originalAllowed = false

    private struct PendingBatch {
        let quality: DownloadQuality
        let title: String
    }

    private var availableQualities: [DownloadQuality] {
        DownloadQuality.allCases.filter { $0 != .original || originalAllowed }
    }

    var body: some View {
        Menu {
            menuContent
        } label: {
            label
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .disabled(isLoading)
        .task(id: seasonEpisodes.first?.id) { await refreshOriginalAllowed() }
        .confirmationDialog("Select Quality", isPresented: $showingQuality, titleVisibility: .visible) {
            ForEach(availableQualities) { quality in
                Button("\(quality.displayName) \u{2014} \(quality.subtitle)") { chooseQuality(quality) }
            }
            Button("Cancel", role: .cancel) { candidates = [] }
        } message: {
            Text("\(candidates.count) episode\(candidates.count == 1 ? "" : "s")")
        }
        .alert(
            pendingBatch?.title ?? "",
            isPresented: isPresenting($pendingBatch),
            presenting: pendingBatch
        ) { batch in
            Button("Download") { enqueue(batch.quality) }
            Button("Cancel", role: .cancel) { candidates = [] }
        }
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
        .alert("Nothing to Download", isPresented: isPresenting($notice)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(notice ?? "")
        }
    }

    @ViewBuilder
    private var menuContent: some View {
        if seriesId != nil {
            Section("Series") {
                Button(BulkDownloadScope.seriesUnwatched.title) { begin(.seriesUnwatched) }
                Button(BulkDownloadScope.series.title) { begin(.series) }
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
        if isLoading {
            ProgressView()
                .scaleEffect(0.7)
        } else if compact {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 20))
        } else {
            Label("Download", systemImage: "arrow.down.circle")
                .font(.system(size: 14, weight: .semibold))
        }
    }

    // MARK: - Actions

    private func begin(_ scope: BulkDownloadScope) {
        Task {
            isLoading = true
            defer { isLoading = false }
            guard let source = await episodes(for: scope) else {
                notice = "Couldn't load this series' episodes. Try again."
                return
            }
            let selected = BulkDownloadPlanner.select(scope, from: source)
            let pending = BulkDownloadPlanner.pending(selected) { itemId in
                downloadManager.downloadStatus(for: itemId, serverID: serverID)?.status
            }
            guard !pending.isEmpty else {
                notice = selected.isEmpty
                    ? "There are no \(scope.isUnwatchedOnly ? "unwatched " : "")episodes to download."
                    : "Every episode is already downloaded or queued."
                return
            }
            candidates = pending
            // Let a dismissing menu/alert finish before presenting the dialog.
            try? await Task.sleep(for: .milliseconds(300))
            showingQuality = true
        }
    }

    private func episodes(for scope: BulkDownloadScope) async -> [BaseItemDto]? {
        guard scope.spansSeries else { return seasonEpisodes }
        guard let seriesId else { return nil }
        return try? await JellyfinClient.shared.getEpisodes(seriesId: seriesId)
    }

    private func chooseQuality(_ quality: DownloadQuality) {
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

    private func enqueue(_ quality: DownloadQuality) {
        downloadManager.downloadSeason(episodes: candidates, quality: quality, serverID: serverID)
        candidates = []
    }

    private func refreshOriginalAllowed() async {
        originalAllowed = false
        guard NetworkMonitor.shared.isOnline, let first = seasonEpisodes.first else { return }
        do {
            let info = try await JellyfinClient.shared.getPlaybackInfo(
                itemId: first.id, itemType: first.type, engine: .avFoundation
            )
            originalAllowed = info.mediaSources?.first
                .map { DeviceMediaCompatibility.canDirectPlayOnDevice($0) } ?? false
        } catch {
            originalAllowed = false
        }
    }

    private func isPresenting<T>(_ value: Binding<T?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}
