import SwiftUI
import SwiftData

struct DownloadButton: View {
    let item: BaseItemDto
    let quality: Binding<DownloadQuality>?
    var showQualityPicker: Bool = true

    @State private var downloadState: DownloadButtonState = .notDownloaded
    @State private var progress: Double = 0
    @State private var showingQualitySheet = false
    @State private var showingDeleteConfirmation = false
    // Cached after the first playback-info fetch so re-taps don't refetch.
    // Fails closed to `.no` (hide Original) on any error.
    @State private var originalAllowed: OriginalAvailability = .undetermined
    @State private var determiningOptions = false
    @ObservedObject private var downloadManager = DownloadManager.shared
    @Environment(\.horizontalSizeClass) private var sizeClass

    private enum DownloadButtonState {
        case notDownloaded
        case queued
        case preparing
        case downloading
        case paused
        case completed
        case failed
    }

    /// Tri-state for whether the raw source can direct-play (offer "Original").
    private enum OriginalAvailability {
        case undetermined
        case yes
        case no
    }

    var body: some View {
        Button {
            handleTap()
        } label: {
            label
        }
        .buttonStyle(.bordered)
        .tint(.white)
        .onAppear { refreshState() }
        .onChange(of: downloadManager.stateVersion) { _, _ in refreshState() }
        // DownloadButton is recycled in ForEach/LazyVStack; `item` is a `let`,
        // so SwiftUI won't reset @State when a reused view gets a new item.
        // Clear cached Original availability so we don't show a stale result.
        .onChange(of: item.id) { _, _ in
            originalAllowed = .undetermined
            determiningOptions = false
        }
        .confirmationDialog("Download Quality", isPresented: $showingQualitySheet) {
            qualityOptions
        } message: {
            if originalAllowed == .no {
                Text("Original isn't available — this file's format can't play offline on this device.")
            }
        }
        .confirmationDialog("Remove Download?", isPresented: $showingDeleteConfirmation) {
            Button("Remove Download", role: .destructive) {
                Task { await downloadManager.deleteDownload(itemId: item.id) }
            }
        } message: {
            Text("This will remove the downloaded file from your device.")
        }
    }

    @ViewBuilder
    private var label: some View {
        switch downloadState {
        case .notDownloaded:
            if determiningOptions {
                ProgressView()
                    .scaleEffect(0.7)
            } else if sizeClass == .compact {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 20))
            } else {
                Label("Download", systemImage: "arrow.down.circle")
                    .font(.system(size: 14, weight: .semibold))
            }

        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 20))
                .foregroundStyle(MobileColors.textSecondary)

        case .preparing:
            ProgressView()
                .scaleEffect(0.7)

        case .downloading:
            if progress < 0 {
                ProgressView()
                    .scaleEffect(0.7)
            } else {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .scaleEffect(0.7)
            }

        case .paused:
            Image(systemName: "pause.circle")
                .font(.system(size: 20))
                .foregroundStyle(MobileColors.warning)

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(MobileColors.success)

        case .failed:
            Label("Retry", systemImage: "exclamationmark.triangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MobileColors.error)
        }
    }

    // Drops .original unless the source is confirmed device-compatible.
    private var availableQualities: [DownloadQuality] {
        DownloadQuality.allCases.filter { $0 != .original || originalAllowed == .yes }
    }

    @ViewBuilder
    private var qualityOptions: some View {
        ForEach(availableQualities) { option in
            Button("\(option.displayName) — \(option.subtitle)") {
                downloadManager.enqueueDownload(item: item, quality: option)
            }
        }
        Button("Cancel", role: .cancel) {}
    }

    private func handleTap() {
        switch downloadState {
        case .notDownloaded:
            if showQualityPicker {
                presentQualitySheet()
            } else if let quality {
                enqueueBoundQuality(quality.wrappedValue)
            } else {
                presentQualitySheet()
            }

        case .queued, .preparing, .downloading:
            Task { await downloadManager.cancelDownload(itemId: item.id) }

        case .paused:
            Task { await downloadManager.retryDownload(itemId: item.id) }

        case .completed:
            showingDeleteConfirmation = true

        case .failed:
            Task { await downloadManager.retryDownload(itemId: item.id) }
        }
    }

    /// Determines Original compatibility (if not already cached), then shows
    /// the quality sheet. While the playback-info fetch is in flight a loading
    /// affordance is shown in the button label.
    private func presentQualitySheet() {
        if originalAllowed != .undetermined {
            showingQualitySheet = true
            return
        }
        Task {
            await determineOriginalAllowed()
            showingQualitySheet = true
        }
    }

    /// Enqueues a pre-bound quality. If the bound quality is .original but the
    /// source isn't device-compatible, downgrade to .high rather than silently
    /// downloading an unplayable original.
    private func enqueueBoundQuality(_ requested: DownloadQuality) {
        guard !determiningOptions else { return }
        guard requested == .original else {
            downloadManager.enqueueDownload(item: item, quality: requested)
            return
        }
        Task {
            await determineOriginalAllowed()
            let resolved: DownloadQuality = (originalAllowed == .yes) ? .original : .high
            downloadManager.enqueueDownload(item: item, quality: resolved)
        }
    }

    /// Fetches playback info once and caches whether the raw source will
    /// direct-play. Fails closed: any thrown error yields false.
    @MainActor
    private func determineOriginalAllowed() async {
        guard originalAllowed == .undetermined else { return }
        determiningOptions = true
        defer { determiningOptions = false }
        do {
            let info = try await JellyfinClient.shared.getPlaybackInfo(itemId: item.id)
            let compatible = info.mediaSources?.first
                .map { DeviceMediaCompatibility.canDirectPlayOnDevice($0) } ?? false
            originalAllowed = compatible ? .yes : .no
        } catch {
            originalAllowed = .no
        }
    }

    private func refreshState() {
        guard let record = downloadManager.downloadStatus(for: item.id) else {
            downloadState = .notDownloaded
            progress = 0
            return
        }

        switch record.status {
        case .queued:
            downloadState = .queued
        case .preparing, .downloading:
            if downloadManager.preparingItems.contains(item.id) {
                downloadState = .preparing
            } else {
                downloadState = .downloading
                progress = downloadManager.activeDownloads[item.id] ?? record.progress
            }
        case .paused:
            downloadState = .paused
        case .completed:
            downloadState = .completed
        case .failed:
            downloadState = .failed
        }
    }
}
