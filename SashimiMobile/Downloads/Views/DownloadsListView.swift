import SwiftUI
import SwiftData

// The list owns sections, selection, confirmations and the actions behind
// them; the rows themselves live in DownloadRows.swift.
// swiftlint:disable type_body_length
struct DownloadsListView: View {
    @Query(sort: \DownloadedItem.dateAdded, order: .reverse) private var downloads: [DownloadedItem]
    @ObservedObject private var downloadManager = DownloadManager.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @ObservedObject private var watchStore = DownloadWatchStateStore.shared
    @State private var showingDeleteAll = false
    @State private var playingItem: BaseItemDto?
    @State private var playingServerID: String?
    @State private var showRoute: ShowRoute?
    @State private var isEditing = false
    @State private var selection: Set<String> = []
    @State private var pendingRemoval: RemovalRequest?
    @AppStorage(DownloadNetworkPolicy.allowCellularKey) private var downloadOverCellular = false
    @AppStorage("showReviewRatings") private var showReviewRatings = true

    /// Why downloads can't move right now, if they can't.
    private var waitReason: DownloadWaitReason? {
        DownloadNetworkPolicy.waitReason(
            allowCellular: downloadOverCellular,
            network: DownloadNetworkStatus(
                isConnected: networkMonitor.isConnected,
                isExpensive: networkMonitor.isExpensive,
                isConstrained: networkMonitor.isConstrained
            )
        )
    }

    /// Destination of a show header's "Go to show". A button plus
    /// navigationDestination rather than a NavigationLink: inside a List a
    /// link takes over the whole row (and adds a second chevron).
    private struct ShowRoute: Hashable, Identifiable {
        let item: BaseItemDto
        let serverID: String?
        var id: String { "\(serverID ?? "legacy"):\(item.id)" }
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// A deletion that needs confirming: Remove watched, or Edit mode's Delete.
    private struct RemovalRequest: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let confirmLabel: String
        let items: [(itemId: String, serverID: String?)]
    }

    var body: some View {
        Group {
            if downloads.isEmpty {
                emptyState
            } else {
                downloadsList
            }
        }
        .background(MobileColors.background)
        .navigationTitle("Downloads")
        .navigationDestination(item: $showRoute) { route in
            AdaptiveDetailView(item: route.item, serverID: route.serverID)
        }
        .fullScreenPlayer(item: $playingItem, serverID: playingServerID)
        .confirmationDialog("Delete All Downloads?", isPresented: $showingDeleteAll) {
            Button("Delete All", role: .destructive) {
                Task {
                    await downloadManager.deleteAllDownloads()
                    // Leaves no rows, so no selection to keep.
                    endEditing()
                }
            }
        } message: {
            Text("This will remove all downloaded files from your device. This cannot be undone.")
        }
        .confirmationDialog(
            pendingRemoval?.title ?? "",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { request in
            Button(request.confirmLabel, role: .destructive) {
                delete(request.items)
            }
        } message: { request in
            Text(request.message)
        }
        .task(id: completedKey) { await refreshWatchState() }
        .onReceive(NotificationCenter.default.publisher(for: .playbackDidStop)) { _ in
            Task { await refreshWatchState() }
        }
        .onChange(of: completedKey) { _, _ in
            // Rows that went away (deleted elsewhere) leave the selection.
            selection.formIntersection(Set(completedItems.map(\.recordID)))
            if completedItems.isEmpty { endEditing() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: MobileSpacing.md) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 48))
                .foregroundStyle(MobileColors.textTertiary)
            Text("No Downloads")
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
            Text("Downloaded movies and episodes will appear here for offline viewing.")
                .font(MobileTypography.body)
                .foregroundStyle(MobileColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Derived state

    private var completedItems: [DownloadedItem] {
        downloads.filter(\.isComplete)
    }

    private var completedKey: String {
        completedItems.map(\.recordID).joined(separator: ",")
    }

    private var watchStates: [String: DownloadWatchState] {
        var states: [String: DownloadWatchState] = [:]
        for item in completedItems {
            states[item.recordID] = DownloadWatchPolicy.resolve(
                server: watchStore.serverStates[item.recordID],
                runTimeTicks: item.runTimeTicks,
                localPositionTicks: item.lastPlaybackPositionTicks,
                localNeedsSync: item.needsProgressSync
            )
        }
        return states
    }

    private func watchedItems(in items: [DownloadedItem], states: [String: DownloadWatchState]) -> [DownloadedItem] {
        let targets = Set(DownloadWatchPolicy.watchedTargets(items.map(\.watchCandidate), states: states).map(\.recordID))
        return items.filter { targets.contains($0.recordID) }
    }

    private static func bytesText(_ items: [DownloadedItem]) -> String {
        ByteCountFormatter.string(
            fromByteCount: DownloadWatchPolicy.totalBytes(items.map(\.watchCandidate)),
            countStyle: .file
        )
    }

    // MARK: - List

    private var downloadsList: some View {
        let states = watchStates
        let completed = completedItems
        let active = downloads.filter { isActive($0) }.sorted { $0.dateAdded < $1.dateAdded }
        let failed = downloads.filter { $0.status == .failed }

        return List {
            Section {
                storageSection(allWatched: watchedItems(in: completed, states: states))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            if !active.isEmpty {
                Section {
                    ForEach(active, id: \.recordID) { item in
                        ActiveDownloadRow(
                            item: item,
                            isPreparing: downloadManager.preparingItems.contains(item.recordID),
                            progress: downloadManager.activeDownloads[item.recordID],
                            waitReason: waitReason,
                            onCancel: {
                                Task { await downloadManager.cancelDownload(itemId: item.itemId, serverID: item.serverID) }
                            }
                        )
                        .cardRow()
                    }
                } header: {
                    sectionHeader("Active")
                }
            }

            if !completed.isEmpty {
                Section {
                    ForEach(DownloadGroup.groups(completed)) { group in
                        completedGroupRows(group, states: states)
                    }
                } header: {
                    sectionHeader("Completed") {
                        Button(isEditing ? "Done" : "Edit") {
                            withAnimation {
                                if isEditing {
                                    endEditing()
                                } else {
                                    isEditing = true
                                }
                            }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(MobileColors.accent)
                    }
                }
            }

            if !failed.isEmpty {
                Section {
                    ForEach(failed, id: \.recordID) { item in
                        // Ticks so the countdown stays current while the list is open.
                        TimelineView(.periodic(from: .now, by: 15)) { context in
                            FailedDownloadRow(
                                item: item,
                                retryNote: downloadManager.retryLabel(
                                    for: item,
                                    now: context.date,
                                    waitReason: waitReason
                                ),
                                onRetry: {
                                    Task { await downloadManager.retryDownload(itemId: item.itemId, serverID: item.serverID) }
                                },
                                onDelete: {
                                    Task { await downloadManager.deleteDownload(itemId: item.itemId, serverID: item.serverID) }
                                }
                            )
                        }
                        .cardRow()
                    }
                } header: {
                    sectionHeader("Failed") {
                        Button("Retry All") {
                            Task { await downloadManager.restartAllFailed() }
                        }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(MobileColors.accent)
                    }
                }
            }

            if !isEditing {
                Section {
                    Button(role: .destructive) {
                        showingDeleteAll = true
                    } label: {
                        Text("Delete All Downloads")
                            .font(MobileTypography.body)
                            .foregroundStyle(MobileColors.error)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .cardRow()
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .listSectionSpacing(MobileSpacing.md)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) {
            if isEditing {
                editBar(completed: completed)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        sectionHeader(title) { EmptyView() }
    }

    private func sectionHeader<Trailing: View>(_ title: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(MobileTypography.headline)
                .foregroundStyle(MobileColors.textPrimary)
            Spacer()
            trailing()
        }
        .textCase(nil)
        .padding(.bottom, 4)
    }

    // MARK: - Storage

    private func storageSection(allWatched: [DownloadedItem]) -> some View {
        let completedCount = completedItems.count

        return HStack(alignment: .center) {
            if !allWatched.isEmpty && !isEditing {
                Button {
                    requestRemoval(
                        of: allWatched,
                        title: "Remove all watched downloads?",
                        what: "watched download"
                    )
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "trash")
                        Text("Remove all watched (\(Self.bytesText(allWatched)))")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MobileColors.error.opacity(0.9))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(MobileColors.cardBackground, in: Capsule())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: MobileSpacing.sm)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(ByteCountFormatter.string(fromByteCount: DownloadFileManager.availableDiskSpace(), countStyle: .file)) available")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(MobileColors.textPrimary)
                if completedCount > 0 {
                    Text("\(completedCount) item\(completedCount == 1 ? "" : "s") · \(DownloadFileManager.formattedTotalSize())")
                        .font(.system(size: 12))
                        .foregroundStyle(MobileColors.textTertiary)
                }
            }

            Image(systemName: "internaldrive")
                .font(.system(size: 18))
                .foregroundStyle(MobileColors.textTertiary)
        }
        .padding(.vertical, MobileSpacing.xs)
    }

    // MARK: - Completed

    @ViewBuilder
    private func completedGroupRows(_ group: DownloadGroup, states: [String: DownloadWatchState]) -> some View {
        if group.isShow, let first = group.items.first {
            let watched = watchedItems(in: group.items, states: states)
            DownloadShowHeader(
                episode: first,
                episodeCount: group.items.count,
                watchedCount: watched.count,
                watchedBytes: DownloadWatchPolicy.totalBytes(watched.map(\.watchCandidate)),
                showsGoToShow: networkMonitor.isConnected,
                isEditing: isEditing,
                allSelected: group.items.allSatisfy { selection.contains($0.recordID) },
                onGoToShow: { showRoute = ShowRoute(item: first.asSeriesDto, serverID: first.serverID) },
                onRemoveWatched: {
                    requestRemoval(
                        of: watched,
                        title: "Remove watched episodes of \(first.seriesName ?? first.name)?",
                        what: "watched episode"
                    )
                }
            )
            .onTapGesture {
                guard isEditing else { return }
                toggleGroup(group)
            }
            .cardRow()

            ForEach(group.items, id: \.recordID) { item in
                completedRow(item, isEpisode: true, states: states)
            }
        } else if let movie = group.items.first {
            completedRow(movie, isEpisode: false, states: states)
        }
    }

    private func completedRow(_ item: DownloadedItem, isEpisode: Bool, states: [String: DownloadWatchState]) -> some View {
        CompletedDownloadRow(
            item: item,
            isEpisode: isEpisode,
            watchState: states[item.recordID] ?? .unwatched,
            communityRating: showReviewRatings ? watchStore.serverStates[item.recordID]?.communityRating : nil,
            isEditing: isEditing,
            isSelected: selection.contains(item.recordID),
            onPlay: { play(item) }
        )
        // The whole row plays; the play button keeps its own tap.
        .onTapGesture {
            if isEditing {
                toggle(item.recordID)
            } else {
                play(item)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if !isEditing {
                Button(role: .destructive) {
                    let target = (itemId: item.itemId, serverID: item.serverID)
                    Task { await downloadManager.deleteDownload(itemId: target.itemId, serverID: target.serverID) }
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .cardRow()
    }

    // MARK: - Edit mode

    private func editBar(completed: [DownloadedItem]) -> some View {
        let selected = completed.filter { selection.contains($0.recordID) }
        let allSelected = !completed.isEmpty && selected.count == completed.count

        return HStack {
            Button(allSelected ? "Deselect All" : "Select All") {
                selection = allSelected ? [] : Set(completed.map(\.recordID))
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(MobileColors.accent)

            Spacer()

            Button(role: .destructive) {
                requestRemoval(of: selected, title: "Delete selected downloads?", what: "download")
            } label: {
                Text(selected.isEmpty ? "Delete" : "Delete \(selected.count) (\(Self.bytesText(selected)))")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selected.isEmpty ? MobileColors.textTertiary : .white)
                    .padding(.horizontal, MobileSpacing.md)
                    .padding(.vertical, 10)
                    .background(selected.isEmpty ? MobileColors.cardBackground : MobileColors.error, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(selected.isEmpty)
        }
        .padding(.horizontal, MobileSpacing.md)
        .padding(.vertical, MobileSpacing.sm)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
        .background(MobileColors.cardBackground.opacity(0.97).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.5)
        }
    }

    private func toggle(_ recordID: String) {
        if selection.contains(recordID) {
            selection.remove(recordID)
        } else {
            selection.insert(recordID)
        }
    }

    private func toggleGroup(_ group: DownloadGroup) {
        let ids = Set(group.items.map(\.recordID))
        if ids.isSubset(of: selection) {
            selection.subtract(ids)
        } else {
            selection.formUnion(ids)
        }
    }

    private func endEditing() {
        isEditing = false
        selection = []
    }

    // MARK: - Actions

    private func requestRemoval(of items: [DownloadedItem], title: String, what: String) {
        guard !items.isEmpty else { return }
        let count = items.count
        let noun = count == 1 ? what : "\(what)s"
        pendingRemoval = RemovalRequest(
            title: title,
            message: "\(count) \(noun) will be removed from this device, freeing \(Self.bytesText(items)).",
            confirmLabel: "Delete \(count) \(noun)",
            items: items.map { (itemId: $0.itemId, serverID: $0.serverID) }
        )
    }

    private func delete(_ items: [(itemId: String, serverID: String?)]) {
        pendingRemoval = nil
        Task {
            await downloadManager.deleteDownloads(items)
            endEditing()
        }
    }

    private func play(_ item: DownloadedItem) {
        ThemeSongPlayer.shared.stopForPlayback()
        playingServerID = item.serverID
        playingItem = item.asBaseItemDto
    }

    private func refreshWatchState() async {
        guard networkMonitor.isConnected else { return }
        await watchStore.refresh(completedItems.map {
            DownloadWatchStateStore.ItemRef(recordID: $0.recordID, itemID: $0.itemId, serverID: $0.serverID)
        })
    }

    private func isActive(_ item: DownloadedItem) -> Bool {
        if downloadManager.preparingItems.contains(item.recordID) { return true }
        if downloadManager.activeDownloads[item.recordID] != nil { return true }
        let status = item.status
        return status == .queued || status == .downloading || status == .preparing
    }
}

private extension View {
    /// A row on the dark card background, edge to edge, without the system
    /// separators (the cards read as one surface, as before the List).
    func cardRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowBackground(MobileColors.cardBackground)
            .listRowSeparator(.hidden)
    }
}
