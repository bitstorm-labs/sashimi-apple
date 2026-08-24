import Foundation
import SwiftData

/// Background SwiftData helper for download operations.
/// Owns a dedicated serial DispatchQueue and ModelContext to keep
/// all database work off the main actor.
final class DownloadPersistence {
    struct PendingPlaybackSync {
        let itemID: String
        let positionTicks: Int64
        let serverID: String?
    }

    private let queue = DispatchQueue(label: "com.mondominator.sashimi.downloadPersistence")
    private var modelContext: ModelContext?

    func setModelContainer(_ container: ModelContainer) {
        queue.sync {
            self.modelContext = ModelContext(container)
        }
    }

    // MARK: - Record Lookup

    /// SwiftData cannot express a composite key with the existing lightweight
    /// store, so fetch the small downloads table and match both identities in
    /// memory. Legacy records without a server ID remain addressable by the
    /// unscoped fallback while new records use an exact server match.
    private func record(
        itemId: String,
        serverID: String?,
        in context: ModelContext
    ) -> DownloadedItem? {
        guard let records = try? context.fetch(FetchDescriptor<DownloadedItem>()) else {
            return nil
        }
        if let serverID {
            return records.first { $0.itemId == itemId && $0.serverID == serverID }
        }
        return records.first { $0.itemId == itemId && $0.serverID == nil }
            ?? records.first { $0.itemId == itemId }
    }

    // MARK: - Status Updates (async — non-blocking)

    func updateStatus(
        itemId: String,
        serverID: String? = nil,
        status: DownloadStatus,
        errorMessage: String? = nil
    ) {
        queue.async { [weak self] in
            guard let self, let context = self.modelContext,
                  let record = self.record(itemId: itemId, serverID: serverID, in: context) else { return }
            record.status = status
            record.errorMessage = errorMessage
            if status == .completed {
                record.dateCompleted = Date()
                record.progress = 1.0
            }
            try? context.save()
        }
    }

    func updateQuality(itemId: String, serverID: String? = nil, quality: DownloadQuality) {
        queue.async { [weak self] in
            guard let self, let context = self.modelContext,
                  let record = self.record(itemId: itemId, serverID: serverID, in: context) else { return }
            record.downloadQuality = quality
            try? context.save()
        }
    }

    func updateProgress(
        itemId: String,
        serverID: String? = nil,
        progress: Double,
        downloadedBytes: Int64,
        totalBytes: Int64
    ) {
        queue.async { [weak self] in
            guard let self, let context = self.modelContext,
                  let record = self.record(itemId: itemId, serverID: serverID, in: context) else { return }
            record.progress = progress
            record.downloadedBytes = downloadedBytes
            record.totalBytes = totalBytes
            try? context.save()
        }
    }

    func markCompleted(
        itemId: String,
        serverID: String? = nil,
        videoFileName: String,
        totalBytes: Int64
    ) {
        queue.async { [weak self] in
            guard let self, let context = self.modelContext,
                  let record = self.record(itemId: itemId, serverID: serverID, in: context) else { return }
            record.videoFileName = videoFileName
            record.totalBytes = totalBytes
            record.status = .completed
            record.dateCompleted = Date()
            record.progress = 1.0
            try? context.save()
        }
    }

    func deleteRecord(itemId: String, serverID: String? = nil) {
        queue.async { [weak self] in
            guard let self, let context = self.modelContext,
                  let record = self.record(itemId: itemId, serverID: serverID, in: context) else { return }
            context.delete(record)
            try? context.save()
        }
    }

    // MARK: - Queries (sync — returns values, but fast)

    func fetchStatus(itemId: String, serverID: String? = nil) -> DownloadStatus? {
        queue.sync {
            guard let context = modelContext else { return nil }
            return record(itemId: itemId, serverID: serverID, in: context)?.status
        }
    }

    func fetchQuality(itemId: String, serverID: String? = nil) -> DownloadQuality? {
        queue.sync {
            guard let context = modelContext else { return nil }
            return record(itemId: itemId, serverID: serverID, in: context)?.downloadQuality
        }
    }

    // MARK: - Asset Updates (async — non-blocking)

    func updatePosterFileName(itemId: String, serverID: String? = nil, fileName: String) {
        queue.async { [weak self] in
            guard let self, let context = self.modelContext,
                  let record = self.record(itemId: itemId, serverID: serverID, in: context) else { return }
            record.posterFileName = fileName
            try? context.save()
        }
    }

    func updateBackdropFileName(itemId: String, serverID: String? = nil, fileName: String) {
        queue.async { [weak self] in
            guard let self, let context = self.modelContext,
                  let record = self.record(itemId: itemId, serverID: serverID, in: context) else { return }
            record.backdropFileName = fileName
            try? context.save()
        }
    }

    func addSubtitle(
        itemId: String,
        serverID: String? = nil,
        language: String,
        displayTitle: String,
        subtitleIndex: Int,
        fileName: String
    ) {
        queue.async { [weak self] in
            guard let self, let context = self.modelContext,
                  let record = self.record(itemId: itemId, serverID: serverID, in: context) else { return }
            let subtitle = DownloadedSubtitle(
                language: language,
                displayTitle: displayTitle,
                subtitleIndex: subtitleIndex,
                fileName: fileName
            )
            record.subtitles.append(subtitle)
            try? context.save()
        }
    }

    // MARK: - Offline Progress (async writes, sync reads)

    func savePlaybackPosition(itemId: String, serverID: String? = nil, positionTicks: Int64) {
        queue.async { [weak self] in
            guard let self, let context = self.modelContext,
                  let record = self.record(itemId: itemId, serverID: serverID, in: context) else { return }
            record.lastPlaybackPositionTicks = positionTicks
            record.needsProgressSync = true
            try? context.save()
        }
    }

    func fetchPendingSync() -> [PendingPlaybackSync] {
        queue.sync {
            guard let context = modelContext,
                  let items = try? context.fetch(FetchDescriptor<DownloadedItem>()) else { return [] }
            return items.filter(\.needsProgressSync).map {
                PendingPlaybackSync(
                    itemID: $0.itemId,
                    positionTicks: $0.lastPlaybackPositionTicks,
                    serverID: $0.serverID
                )
            }
        }
    }

    func clearSyncFlag(itemId: String, serverID: String? = nil) {
        queue.async { [weak self] in
            guard let self, let context = self.modelContext,
                  let record = self.record(itemId: itemId, serverID: serverID, in: context) else { return }
            record.needsProgressSync = false
            try? context.save()
        }
    }

    func deleteAllRecords() {
        queue.async { [weak self] in
            guard let context = self?.modelContext,
                  let items = try? context.fetch(FetchDescriptor<DownloadedItem>()) else { return }
            items.forEach { context.delete($0) }
            try? context.save()
        }
    }
}
