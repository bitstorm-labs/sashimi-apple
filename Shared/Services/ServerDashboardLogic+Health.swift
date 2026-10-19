import Foundation

// Health, storage and the phone's "Needs attention" list.
extension ServerDashboardLogic {
    private static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "" }
        let relative = relativeTime(date, now: now)
        return relative == "now" ? "now" : "\(relative) ago"
    }

    // MARK: - Storage

    static let storageWarningThreshold = 0.85

    static func isStorageWarning(free: Int64, used: Int64) -> Bool {
        let total = free + used
        guard total > 0 else { return false }
        return Double(used) / Double(total) > storageWarningThreshold
    }

    static func storageRows(_ storage: SystemStorageInfo) -> [DashboardHealthRow] {
        var rows: [DashboardHealthRow] = []
        var drives: [String: SystemStorageInfo.FolderStorage] = [:]
        for folder in storage.libraries.flatMap(\.folders) {
            drives[folder.deviceId ?? "\(folder.freeSpace)/\(folder.usedSpace)"] = folder
        }
        if !drives.isEmpty {
            let free = drives.values.map(\.freeSpace).reduce(0, +)
            let used = drives.values.map(\.usedSpace).reduce(0, +)
            let warn = isStorageWarning(free: free, used: used)
            rows.append(DashboardHealthRow(
                title: "Media storage",
                value: "\(formatBytes(free)) free of \(formatBytes(free + used))",
                tone: warn ? .warning : .ok,
                attentionText: "Media storage \(percentUsed(free: free, used: used))% full"
            ))
        }
        if let cache = storage.transcodingTempFolder, cache.freeSpace + cache.usedSpace > 0 {
            let warn = isStorageWarning(free: cache.freeSpace, used: cache.usedSpace)
            rows.append(DashboardHealthRow(
                title: "Cache drive",
                value: "\(percentUsed(free: cache.freeSpace, used: cache.usedSpace))% full",
                tone: warn ? .warning : .ok
            ))
        }
        return rows
    }

    private static func percentUsed(free: Int64, used: Int64) -> Int {
        let total = free + used
        guard total > 0 else { return 0 }
        return Int((Double(used) / Double(total) * 100).rounded())
    }

    /// Decimal units, as drives are sold: "8.2 TB", "46 TB", "150 B".
    static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        if unit == 0 || value >= 10 { return "\(Int(value.rounded())) \(units[unit])" }
        return String(format: "%.1f %@", value, units[unit])
    }

    // MARK: - Health

    private static let failedStatuses: Set<String> = ["Failed", "Aborted"]

    static func healthRows(
        tasks: [ScheduledTaskInfo],
        storage: SystemStorageInfo?,
        encoding: EncodingOptionsSummary?,
        sessions: [DashboardSession],
        now: Date
    ) -> [DashboardHealthRow] {
        var rows: [DashboardHealthRow] = []
        if let scan = tasks.first(where: { $0.key == "RefreshLibrary" }) {
            rows.append(libraryScanRow(scan, now: now))
        }
        for task in tasks where task.key != "RefreshLibrary" {
            guard let result = task.lastExecutionResult, failedStatuses.contains(result.status ?? "") else { continue }
            rows.append(DashboardHealthRow(
                title: task.name,
                value: "Failed · \(ago(result.endTimeUtc, now: now))",
                tone: .failure,
                attentionText: "\(task.name) failed",
                when: result.endTimeUtc.map { relativeTime($0, now: now) }
            ))
        }
        if let storage { rows += storageRows(storage) }
        if let encoding { rows.append(hardwareRow(encoding, sessions: sessions)) }
        return rows
    }

    private static func libraryScanRow(_ scan: ScheduledTaskInfo, now: Date) -> DashboardHealthRow {
        let title = "Library scan"
        if scan.state == "Running" { return DashboardHealthRow(title: title, value: "Running", tone: .ok) }
        guard let result = scan.lastExecutionResult else {
            return DashboardHealthRow(title: title, value: "Never run", tone: .neutral)
        }
        let when = ago(result.endTimeUtc, now: now)
        switch result.status {
        case "Completed":
            return DashboardHealthRow(title: title, value: "OK · \(when)", tone: .ok)
        case let status? where failedStatuses.contains(status):
            return DashboardHealthRow(
                title: title, value: "Failed · \(when)", tone: .failure,
                attentionText: "Library scan failed", when: result.endTimeUtc.map { relativeTime($0, now: now) }
            )
        default:
            return DashboardHealthRow(title: title, value: "Cancelled · \(when)", tone: .neutral)
        }
    }

    private static let accelerationNames: [String: String] = [
        "qsv": "QSV", "vaapi": "VA-API", "nvenc": "NVENC", "amf": "AMF",
        "videotoolbox": "VideoToolbox", "v4l2m2m": "V4L2", "rkmpp": "RKMPP"
    ]

    /// "qsv" → "QSV".
    static func accelerationName(_ type: String) -> String {
        accelerationNames[type.lowercased()] ?? type.uppercased()
    }

    private static func hardwareRow(_ encoding: EncodingOptionsSummary, sessions: [DashboardSession]) -> DashboardHealthRow {
        let type = (encoding.hardwareAccelerationType ?? "").lowercased()
        guard !type.isEmpty, type != "none" else {
            return DashboardHealthRow(title: "Hardware transcoding", value: "Off", tone: .neutral)
        }
        let name = accelerationName(type)
        let inUse = sessions.filter(isHardware).count
        let value: String
        switch inUse {
        case 0: value = "Ready"
        case 1: value = "In use · 1 stream"
        default: value = "In use · \(inUse) streams"
        }
        return DashboardHealthRow(title: "Hardware transcoding (\(name))", value: value, tone: .ok)
    }

    // MARK: - Needs attention (phone)

    static func attention(activity: [DashboardActivityRow], health: [DashboardHealthRow]) -> [DashboardAttentionRow] {
        let fromActivity = activity.filter(\.tone.needsAttention).map {
            DashboardAttentionRow(id: "activity-\($0.id)", text: $0.text, when: $0.when, tone: $0.tone)
        }
        let fromHealth = health.filter(\.tone.needsAttention).map {
            DashboardAttentionRow(
                id: "health-\($0.title)",
                text: $0.attentionText ?? "\($0.title) \($0.value)",
                when: $0.when ?? "now",
                tone: $0.tone
            )
        }
        return fromActivity + fromHealth
    }
}
