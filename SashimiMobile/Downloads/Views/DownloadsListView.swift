import SwiftUI
import SwiftData

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
        List {
            // Storage summary
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Storage Used")
                            .font(MobileTypography.caption)
                            .foregroundStyle(MobileColors.textSecondary)
                        Text(DownloadFileManager.formattedTotalSize())
                            .font(MobileTypography.title)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Available")
                            .font(MobileTypography.caption)
                            .foregroundStyle(MobileColors.textSecondary)
                        Text(ByteCountFormatter.string(
                            fromByteCount: DownloadFileManager.availableDiskSpace(),
                            countStyle: .file
                        ))
                        .font(MobileTypography.title)
                    }
                }
            }

            // Active downloads
            let active = downloads.filter { !$0.isComplete }
            if !active.isEmpty {
                Section("Downloading") {
                    ForEach(active, id: \.itemId) { item in
                        downloadRow(item)
                    }
                }
            }

            // Completed downloads
            let completed = downloads.filter { $0.isComplete }
            if !completed.isEmpty {
                Section("Downloaded") {
                    ForEach(completed, id: \.itemId) { item in
                        downloadRow(item)
                    }
                    .onDelete { indexSet in
                        for index in indexSet {
                            let item = completed[index]
                            Task { await downloadManager.deleteDownload(itemId: item.itemId) }
                        }
                    }
                }
            }

            // Delete all
            if !downloads.isEmpty {
                Section {
                    Button("Delete All Downloads", role: .destructive) {
                        showingDeleteAll = true
                    }
                }
            }
        }
    }

    private func downloadRow(_ item: DownloadedItem) -> some View {
        HStack(spacing: MobileSpacing.md) {
            // Poster thumbnail
            if let posterFileName = item.posterFileName {
                let posterURL = DownloadFileManager.itemDirectory(for: item.itemId)
                    .appendingPathComponent(posterFileName)
                AsyncImage(url: posterURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(MobileColors.cardBackground)
                }
                .frame(width: 60, height: 90)
                .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))
            } else {
                Rectangle()
                    .fill(MobileColors.cardBackground)
                    .frame(width: 60, height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: MobileCornerRadius.small))
                    .overlay {
                        Image(systemName: "film")
                            .foregroundStyle(MobileColors.textTertiary)
                    }
            }

            // Info
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(MobileTypography.title)
                    .foregroundStyle(MobileColors.textPrimary)
                    .lineLimit(2)

                if item.isComplete {
                    Text(item.formattedSize)
                        .font(MobileTypography.caption)
                        .foregroundStyle(MobileColors.textSecondary)
                } else {
                    statusLabel(for: item)
                }

                if item.status == .downloading {
                    ProgressView(value: downloadManager.activeDownloads[item.itemId] ?? item.progress)
                        .tint(MobileColors.accent)
                }
            }

            Spacer()

            // Action button
            actionButton(for: item)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusLabel(for item: DownloadedItem) -> some View {
        switch item.status {
        case .queued:
            Text("Waiting...")
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.textSecondary)
        case .preparing:
            HStack(spacing: 6) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Preparing...")
                    .font(MobileTypography.caption)
                    .foregroundStyle(MobileColors.textSecondary)
            }
        case .downloading:
            let pct = Int((downloadManager.activeDownloads[item.itemId] ?? item.progress) * 100)
            Text("Downloading \(pct)%")
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.accent)
        case .paused:
            Text("Paused")
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.warning)
        case .failed:
            Text(item.errorMessage ?? "Failed")
                .font(MobileTypography.caption)
                .foregroundStyle(MobileColors.error)
                .lineLimit(1)
        case .completed:
            EmptyView()
        }
    }

    @ViewBuilder
    private func actionButton(for item: DownloadedItem) -> some View {
        switch item.status {
        case .queued, .preparing, .downloading:
            Button {
                Task { await downloadManager.cancelDownload(itemId: item.itemId) }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(MobileColors.textSecondary)
            }
            .buttonStyle(.plain)

        case .paused:
            Button {
                Task { await downloadManager.retryDownload(itemId: item.itemId) }
            } label: {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(MobileColors.accent)
            }
            .buttonStyle(.plain)

        case .failed:
            Button {
                Task { await downloadManager.retryDownload(itemId: item.itemId) }
            } label: {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title3)
                    .foregroundStyle(MobileColors.warning)
            }
            .buttonStyle(.plain)

        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(MobileColors.success)
        }
    }
}
