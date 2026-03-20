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
        .confirmationDialog("Download Quality", isPresented: $showingQualitySheet) {
            qualityOptions
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
            if sizeClass == .compact {
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

    @ViewBuilder
    private var qualityOptions: some View {
        ForEach(DownloadQuality.allCases) { option in
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
                showingQualitySheet = true
            } else if let quality {
                downloadManager.enqueueDownload(item: item, quality: quality.wrappedValue)
            } else {
                showingQualitySheet = true
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
