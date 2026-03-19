import SwiftUI
import SwiftData
import NukeUI

// swiftlint:disable type_body_length
struct DownloadsListView: View {
    @Query(sort: \DownloadedItem.dateAdded, order: .reverse) private var downloads: [DownloadedItem]
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var showingDeleteAll = false

    var body: some View {
        Group {
            if downloads.isEmpty {
                emptyState
            } else {
                downloadsList
            }
        }
        .navigationTitle("Downloads")
        .confirmationDialog("Delete All Downloads?", isPresented: $showingDeleteAll) {
            Button("Delete All", role: .destructive) {
                Task { await downloadManager.deleteAllDownloads() }
            }
        } message: {
            Text("This will remove all downloaded files from your device. This cannot be undone.")
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

    private var downloadsList: some View {
        ScrollView {
            VStack(spacing: MobileSpacing.lg) {
                // Storage bar
                storageSection
                    .padding(.horizontal, MobileSpacing.md)

                // Active downloads
                let active = downloads.filter { isActive($0) }.sorted { $0.dateAdded < $1.dateAdded }
                if !active.isEmpty {
                    VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                        Text("Active")
                            .font(MobileTypography.headline)
                            .foregroundStyle(MobileColors.textPrimary)
                            .padding(.horizontal, MobileSpacing.md)

                        VStack(spacing: 1) {
                            ForEach(active, id: \.itemId) { item in
                                activeDownloadRow(item)
                            }
                        }
                        .background(MobileColors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
                        .padding(.horizontal, MobileSpacing.md)
                    }
                }

                // Completed downloads
                let completed = downloads.filter { $0.isComplete }
                if !completed.isEmpty {
                    VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                        Text("Completed")
                            .font(MobileTypography.headline)
                            .foregroundStyle(MobileColors.textPrimary)
                            .padding(.horizontal, MobileSpacing.md)

                        VStack(spacing: 1) {
                            ForEach(completed, id: \.itemId) { item in
                                completedDownloadRow(item)
                            }
                        }
                        .background(MobileColors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
                        .padding(.horizontal, MobileSpacing.md)
                    }
                }

                // Failed downloads
                let failed = downloads.filter { $0.status == .failed }
                if !failed.isEmpty {
                    VStack(alignment: .leading, spacing: MobileSpacing.sm) {
                        HStack {
                            Text("Failed")
                                .font(MobileTypography.headline)
                                .foregroundStyle(MobileColors.textPrimary)
                            Spacer()
                            Button("Retry All") {
                                Task { await downloadManager.restartAllFailed() }
                            }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(MobileColors.accent)
                        }
                        .padding(.horizontal, MobileSpacing.md)

                        VStack(spacing: 1) {
                            ForEach(failed, id: \.itemId) { item in
                                failedDownloadRow(item)
                            }
                        }
                        .background(MobileColors.cardBackground)
                        .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
                        .padding(.horizontal, MobileSpacing.md)
                    }
                }

                // Delete all
                if !downloads.isEmpty {
                    Button(role: .destructive) {
                        showingDeleteAll = true
                    } label: {
                        Text("Delete All Downloads")
                            .font(MobileTypography.body)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(MobileColors.cardBackground)
                            .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.medium))
                    }
                    .padding(.horizontal, MobileSpacing.md)
                }

                Spacer().frame(height: 40)
            }
            .padding(.top, MobileSpacing.md)
        }
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Storage

    private var storageSection: some View {
        let completedCount = downloads.filter { $0.isComplete }.count

        return HStack {
            Spacer()

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
        .padding(MobileSpacing.md)
    }

    // MARK: - Active Download Row

    private func activeDownloadRow(_ item: DownloadedItem) -> some View {
        let isPreparing = downloadManager.preparingItems.contains(item.itemId)
        let isDownloading = downloadManager.activeDownloads[item.itemId] != nil && !isPreparing
        let progress = downloadManager.activeDownloads[item.itemId] ?? 0

        return HStack(spacing: MobileSpacing.md) {
            posterImage(for: item)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(1)

                if item.seriesName != nil {
                    Text(item.name)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if isPreparing {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Preparing...")
                        .font(.system(size: 12))
                        .foregroundStyle(MobileColors.textSecondary)
                }
            } else if isDownloading && progress < 0 {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.6)
                    Text("Downloading...")
                        .font(.system(size: 12))
                        .foregroundStyle(MobileColors.accent)
                }
            } else if isDownloading {
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(MobileColors.accent)
            } else {
                Text("Queued")
                    .font(.system(size: 12))
                    .foregroundStyle(MobileColors.textTertiary)
            }

            Button {
                Task { await downloadManager.cancelDownload(itemId: item.itemId) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(MobileColors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(MobileSpacing.md)
    }

    // MARK: - Completed Download Row

    private func completedDownloadRow(_ item: DownloadedItem) -> some View {
        HStack(spacing: MobileSpacing.md) {
            posterImage(for: item)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(1)

                if item.seriesName != nil {
                    Text(item.name)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                        .lineLimit(1)
                }

                Text(item.formattedSize)
                    .font(.system(size: 12))
                    .foregroundStyle(MobileColors.textTertiary)
            }

            Spacer()

            Button {
                Task { await downloadManager.deleteDownload(itemId: item.itemId) }
            } label: {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(MobileColors.textTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(MobileSpacing.md)
    }

    // MARK: - Failed Download Row

    private func failedDownloadRow(_ item: DownloadedItem) -> some View {
        HStack(spacing: MobileSpacing.md) {
            posterImage(for: item)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(1)

                Text(item.errorMessage ?? "Download failed")
                    .font(.system(size: 12))
                    .foregroundStyle(MobileColors.error)
                    .lineLimit(1)
            }

            Spacer()

            HStack(spacing: 12) {
                Button {
                    Task { await downloadManager.retryDownload(itemId: item.itemId) }
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(MobileColors.accent)
                }
                .buttonStyle(.plain)

                Button {
                    Task { await downloadManager.deleteDownload(itemId: item.itemId) }
                } label: {
                    Image(systemName: "trash.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(MobileColors.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(MobileSpacing.md)
    }

    // MARK: - Poster Image

    @ViewBuilder
    private func posterImage(for item: DownloadedItem) -> some View {
        if let serverURL = serverPosterURL(for: item) {
            LazyImage(url: serverURL) { state in
                if let image = state.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    posterPlaceholder
                }
            }
            .frame(width: 60, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            posterPlaceholder
        }
    }

    private var posterPlaceholder: some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(MobileColors.background)
            .frame(width: 60, height: 90)
            .overlay {
                Image(systemName: "film")
                    .font(.system(size: 16))
                    .foregroundStyle(MobileColors.textTertiary)
            }
    }

    private func serverPosterURL(for item: DownloadedItem) -> URL? {
        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL") else { return nil }
        // For episodes, use the series poster if available
        let imageItemId = item.seriesId ?? item.itemId
        return URL(string: "\(serverURL)/Items/\(imageItemId)/Images/Primary?maxWidth=200")
    }

    // MARK: - Helpers

    private func isActive(_ item: DownloadedItem) -> Bool {
        if downloadManager.preparingItems.contains(item.itemId) { return true }
        if downloadManager.activeDownloads[item.itemId] != nil { return true }
        let status = item.status
        return status == .queued || status == .downloading || status == .preparing
    }
}

