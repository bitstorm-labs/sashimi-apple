import Foundation

/// Finds downloads made by the broken transcode URL (#585): before the fix,
/// every High/Medium/Low download was encoded at 1 kbps and 416 px wide —
/// unwatchable — because the URL carried no video bitrate the server's
/// progressive endpoint understands.
///
/// Rather than a SwiftData schema change, the fixed builder records each
/// download it starts (by record ID) in UserDefaults. A completed transcoded
/// download that is NOT in that set was produced by the old URL — including
/// one already in flight in the background session when the app updated —
/// and is offered for re-download. `.original` (a stream copy) was never
/// affected.
enum DownloadEncodingAudit {
    static let fixedRecordsKey = "downloadsWithVideoBitrateRecordIDs"

    static func fixedRecordIDs(defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: fixedRecordsKey) ?? [])
    }

    /// Called when a transcoded download's request is built by the fixed URL.
    static func markEncodedWithVideoBitrate(recordID: String, defaults: UserDefaults = .standard) {
        var ids = fixedRecordIDs(defaults: defaults)
        guard ids.insert(recordID).inserted else { return }
        defaults.set(Array(ids), forKey: fixedRecordsKey)
    }

    /// Called when a download is deleted, so the set doesn't grow forever.
    static func forget(recordID: String, defaults: UserDefaults = .standard) {
        var ids = fixedRecordIDs(defaults: defaults)
        guard ids.remove(recordID) != nil else { return }
        defaults.set(Array(ids), forKey: fixedRecordsKey)
    }

    static func needsRedownload(
        quality: DownloadQuality,
        isComplete: Bool,
        recordID: String,
        fixedRecordIDs: Set<String>
    ) -> Bool {
        isComplete && quality != .original && !fixedRecordIDs.contains(recordID)
    }
}
