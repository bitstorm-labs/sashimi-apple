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

    @Environment(\.modelContext) private var modelContext

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
        .onAppear { refreshState() }
        .onChange(of: downloadManager.activeDownloads) { _, _ in refreshState() }
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
            Label("Download", systemImage: "arrow.down.circle")
                .font(.system(size: 14, weight: .semibold))

        case .queued:
            Label("Queued", systemImage: "clock")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MobileColors.textSecondary)

        case .preparing:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Preparing...")
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(MobileColors.textSecondary)

        case .downloading:
            if progress < 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Downloading...")
                        .font(.system(size: 14, weight: .semibold))
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView(value: progress)
                        .progressViewStyle(.circular)
                        .scaleEffect(0.7)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 14, weight: .semibold))
                }
            }

        case .paused:
            Label("Paused", systemImage: "pause.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(MobileColors.warning)

        case .completed:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
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
