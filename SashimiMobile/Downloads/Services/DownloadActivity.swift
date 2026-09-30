import Foundation

/// Byte and fraction progress of one in-flight download.
struct DownloadItemProgress: Equatable {
    /// 0...1, or negative when the total size is unknown (transcodes).
    var fraction: Double
    var bytesWritten: Int64 = 0
    /// Expected total, or <= 0 when the server didn't send a length.
    var bytesExpected: Int64 = 0
}

/// What the global download indicator shows: how many downloads are active
/// or waiting, and how far the active ones have got.
struct DownloadActivitySnapshot: Equatable {
    /// Active, preparing and queued downloads.
    let activeCount: Int
    /// 0...1 across the active downloads, or nil when it can't be known
    /// (nothing has reported a size or fraction yet); show a spinner then.
    let progress: Double?

    var isActive: Bool { activeCount > 0 }

    static let idle = DownloadActivitySnapshot(activeCount: 0, progress: nil)

    init(activeCount: Int, progress: Double?) {
        self.activeCount = activeCount
        self.progress = progress
    }

    /// `activeKeys` and `preparingKeys` overlap while a task waits for its
    /// first bytes, so they're unioned rather than added.
    init(
        active: [String: DownloadItemProgress],
        preparingKeys: Set<String>,
        queuedCount: Int
    ) {
        activeCount = Set(active.keys).union(preparingKeys).count + max(queuedCount, 0)
        progress = Self.overallProgress(Array(active.values))
    }

    /// Total bytes written / expected when every active item knows its size;
    /// otherwise the average of the per-item fractions that are known.
    static func overallProgress(_ items: [DownloadItemProgress]) -> Double? {
        guard !items.isEmpty else { return nil }
        if items.allSatisfy({ $0.bytesExpected > 0 }) {
            let written = items.reduce(Int64(0)) { $0 + max($1.bytesWritten, 0) }
            let expected = items.reduce(Int64(0)) { $0 + $1.bytesExpected }
            return clamp(Double(written) / Double(expected))
        }
        let known = items.map(\.fraction).filter { $0 >= 0 }
        guard !known.isEmpty else { return nil }
        return clamp(known.reduce(0, +) / Double(known.count))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
