import Foundation

// Pure rules behind the download progress indicator: how big a download with
// no Content-Length is likely to be, how far along it is, how fast it moves
// and what the row says about it. No UI and no I/O beyond the injectable
// UserDefaults store at the bottom.

// MARK: - Size estimate

/// What a size estimate is derived from. Persisted per record (see
/// DownloadEstimateStore) so the estimate can be rebuilt after a relaunch
/// without a SwiftData schema change.
struct DownloadEstimateInput: Codable, Equatable {
    /// DownloadQuality raw value of the tier actually requested.
    var quality: String?
    var runTimeTicks: Int64?
    /// The source file's overall bitrate (bits/s), when the server told us.
    var sourceBitrate: Int?
    /// The source video stream's bitrate (bits/s), when the server told us.
    var sourceVideoBitrate: Int?
}

/// Expected size of a download the server streams without a length (every
/// transcode, and the Original remux).
enum DownloadSizeEstimate {
    /// Bits per second the server is expected to send.
    ///
    /// A tier asks for an explicit video and audio bitrate
    /// (DownloadURLBuilder.transcodedDownloadURL); the server caps the video
    /// at the source's own, so a low-bitrate source comes out smaller than
    /// the tier. Original is a stream copy: the source's bitrate, or nil when
    /// that isn't known.
    static func expectedBitrate(
        quality: DownloadQuality,
        sourceBitrate: Int? = nil,
        sourceVideoBitrate: Int? = nil
    ) -> Int? {
        let source = sourceBitrate.flatMap { $0 > 0 ? $0 : nil }
        guard let tierVideo = quality.videoBitrate, let tierAudio = quality.audioBitrate else {
            return source
        }
        let sourceVideo = sourceVideoBitrate.flatMap { $0 > 0 ? $0 : nil } ?? source
        return min(tierVideo, sourceVideo ?? tierVideo) + tierAudio
    }

    /// Bitrate x runtime / 8, or nil when either is unknown.
    static func expectedBytes(
        quality: DownloadQuality,
        runTimeTicks: Int64?,
        sourceBitrate: Int? = nil,
        sourceVideoBitrate: Int? = nil
    ) -> Int64? {
        guard let ticks = runTimeTicks, ticks > 0,
              let bitrate = expectedBitrate(
                  quality: quality,
                  sourceBitrate: sourceBitrate,
                  sourceVideoBitrate: sourceVideoBitrate
              ) else { return nil }
        let seconds = Double(ticks) / 10_000_000
        return Int64(seconds * Double(bitrate) / 8)
    }

    static func expectedBytes(for input: DownloadEstimateInput) -> Int64? {
        guard let quality = input.quality.flatMap(DownloadQuality.init(rawValue:)) else { return nil }
        return expectedBytes(
            quality: quality,
            runTimeTicks: input.runTimeTicks,
            sourceBitrate: input.sourceBitrate,
            sourceVideoBitrate: input.sourceVideoBitrate
        )
    }
}

// MARK: - Progress

/// How far along one download is, as shown: bytes, the total (exact or
/// estimated) and the fraction of it.
struct DownloadProgressDisplay: Equatable {
    /// The most that is ever shown before the download really completes.
    static let maximumFraction = 0.99
    /// Up to this share of an estimate, progress is simply received / estimate.
    /// Past it the estimate is treated as too small and starts growing.
    static let growthThreshold = 0.9

    var receivedBytes: Int64
    /// Nil when the server sent no length and there is nothing to estimate from.
    var totalBytes: Int64?
    /// True when `totalBytes` is an estimate ("~").
    var isEstimated: Bool
    /// 0...0.99, or nil when there is no total at all.
    var fraction: Double?

    /// An exact total (Content-Length) wins; otherwise the estimate.
    ///
    /// An estimate can be too small. Sticking at 99% of it would look hung,
    /// so past `growthThreshold` the fraction eases toward (never reaching) 1
    /// and the total is restated as received / fraction: the bar keeps
    /// creeping, the total keeps growing ahead of the bytes, and the bytes
    /// still to come stay positive. The curve joins the linear part with the
    /// same slope, so there is no jump at the threshold.
    static func make(
        receivedBytes: Int64,
        exactTotalBytes: Int64?,
        estimatedTotalBytes: Int64?
    ) -> DownloadProgressDisplay {
        let received = max(receivedBytes, 0)
        if let exact = exactTotalBytes, exact > 0 {
            let fraction = min(Double(received) / Double(exact), maximumFraction)
            return DownloadProgressDisplay(
                receivedBytes: received, totalBytes: max(exact, received), isEstimated: false, fraction: fraction
            )
        }
        guard let estimate = estimatedTotalBytes, estimate > 0 else {
            return DownloadProgressDisplay(receivedBytes: received, totalBytes: nil, isEstimated: true, fraction: nil)
        }

        let ratio = Double(received) / Double(estimate)
        guard ratio > growthThreshold else {
            return DownloadProgressDisplay(
                receivedBytes: received, totalBytes: estimate, isEstimated: true, fraction: ratio
            )
        }
        let tail = 1 - growthThreshold
        let overshoot = (ratio - growthThreshold) / tail
        let eased = 1 - tail / (1 + overshoot)
        let fraction = min(eased, maximumFraction)
        let total = max(Int64((Double(received) / fraction).rounded(.up)), estimate, received + 1)
        return DownloadProgressDisplay(receivedBytes: received, totalBytes: total, isEstimated: true, fraction: fraction)
    }
}

/// Everything an active download's row, ring and VoiceOver label show.
struct DownloadProgressDetail: Equatable {
    /// Below this the speed is noise (a stalled download decaying to zero).
    static let minimumSpeed: Double = 1_024
    /// A longer time left than this is a guess, not information.
    static let maximumSecondsRemaining: Double = 24 * 3_600

    var display: DownloadProgressDisplay
    /// Smoothed; nil until there is enough data or while nothing arrives.
    var bytesPerSecond: Double?
    /// Never negative; nil without a speed or a total.
    var secondsRemaining: Double?

    static func make(
        receivedBytes: Int64,
        exactTotalBytes: Int64?,
        estimatedTotalBytes: Int64?,
        bytesPerSecond: Double?
    ) -> DownloadProgressDetail {
        let display = DownloadProgressDisplay.make(
            receivedBytes: receivedBytes,
            exactTotalBytes: exactTotalBytes,
            estimatedTotalBytes: estimatedTotalBytes
        )
        let speed = bytesPerSecond.flatMap { $0.isFinite && $0 >= minimumSpeed ? $0 : nil }
        var remaining: Double?
        if let speed, let total = display.totalBytes, total > display.receivedBytes {
            let seconds = Double(total - display.receivedBytes) / speed
            remaining = seconds <= maximumSecondsRemaining ? seconds : nil
        }
        return DownloadProgressDetail(display: display, bytesPerSecond: speed, secondsRemaining: remaining)
    }
}

// MARK: - Speed

/// Smoothed download speed from the running byte count. Fed on a timer (not
/// only when bytes arrive), so a stalled download decays instead of showing
/// its last speed forever.
struct DownloadSpeedTracker: Equatable {
    /// Samples closer together than this are folded into the next one.
    static let sampleInterval: TimeInterval = 1
    /// Samples needed before a speed is reported.
    static let minimumSamples = 3
    /// Weight of the newest sample in the moving average.
    static let smoothing = 0.3
    /// A gap this long (the app was suspended) restarts the baseline rather
    /// than averaging the gap in.
    static let maximumGap: TimeInterval = 10

    private var lastBytes: Int64?
    private var lastTime: TimeInterval = 0
    private var average: Double = 0
    private var samples = 0

    /// Nil until `minimumSamples` have been taken.
    var bytesPerSecond: Double? {
        samples >= Self.minimumSamples ? average : nil
    }

    mutating func record(totalBytes: Int64, at time: TimeInterval) {
        // Nothing has arrived yet (the server is still starting ffmpeg):
        // waiting isn't speed, so the clock starts with the first bytes.
        guard totalBytes > 0 else { return }
        guard let previous = lastBytes, totalBytes >= previous else {
            // First bytes, or the count went backwards (a restarted task).
            self = DownloadSpeedTracker()
            lastBytes = totalBytes
            lastTime = time
            return
        }
        let elapsed = time - lastTime
        guard elapsed >= Self.sampleInterval else { return }
        defer {
            lastBytes = totalBytes
            lastTime = time
        }
        guard elapsed <= Self.maximumGap else { return }

        let rate = Double(totalBytes - previous) / elapsed
        average = samples == 0 ? rate : Self.smoothing * rate + (1 - Self.smoothing) * average
        samples += 1
    }
}

// MARK: - Text

/// One way of writing an active download's status line. `percent` is drawn
/// emphasised, the rest after it.
struct DownloadStatusLine: Equatable {
    var percent: String?
    var parts: [String]

    var text: String {
        ((percent.map { [$0] } ?? []) + parts).joined(separator: " · ")
    }
}

enum DownloadProgressText {
    /// "43%". Rounded down, and never 100 (see DownloadProgressDisplay).
    static func percent(_ fraction: Double) -> String {
        let capped = min(max(fraction, 0), DownloadProgressDisplay.maximumFraction)
        return "\(Int((capped * 100).rounded(.down)))%"
    }

    /// "182 MB", "4.2 GB", "640 KB". Whole megabytes rather than
    /// ByteCountFormatter's "182.4 MB": the line has to fit a phone, and the
    /// tenths only flicker.
    static func byteCount(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        if value < 999_500 { return "\(Int((value / 1_000).rounded())) KB" }
        if value < 999_500_000 { return "\(Int((value / 1_000_000).rounded())) MB" }
        return String(format: "%.1f GB", value / 1_000_000_000)
    }

    /// "182 MB of ~420 MB", "182 MB of 420 MB" for an exact total, or just
    /// "182 MB" when there is no total.
    static func bytes(_ display: DownloadProgressDisplay) -> String {
        let received = byteCount(display.receivedBytes)
        guard let total = display.totalBytes else { return received }
        return "\(received) of \(display.isEstimated ? "~" : "")\(byteCount(total))"
    }

    /// "3.1 MB/s", "640 KB/s"
    static func speed(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        if value < 999_500 { return "\(Int((value / 1_000).rounded())) KB/s" }
        return String(format: "%.1f MB/s", value / 1_000_000)
    }

    /// "less than a minute left", "about 12 min left", "about 1 hr 20 min
    /// left". Whole minutes (5-minute steps past an hour), so it doesn't
    /// flicker with every change in speed. Nil for a negative or absurd time.
    static func timeLeft(seconds: Double?) -> String? {
        guard let seconds, seconds.isFinite, seconds >= 0,
              seconds <= DownloadProgressDetail.maximumSecondsRemaining else { return nil }
        if seconds < 60 { return "less than a minute left" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "about \(minutes) min left" }
        let rounded = Int((Double(minutes) / 5).rounded()) * 5
        let hours = rounded / 60
        let remainder = rounded % 60
        return remainder == 0 ? "about \(hours) hr left" : "about \(hours) hr \(remainder) min left"
    }

    /// The status line from fullest to shortest. The row shows the first one
    /// that fits its width, so a narrow row drops the time left first, then
    /// the speed, and only then the byte counts.
    static func statusLines(for detail: DownloadProgressDetail) -> [DownloadStatusLine] {
        let percent = detail.display.fraction.map(percent)
        let bytes = bytes(detail.display)
        let speed = detail.bytesPerSecond.map(speed)
        let timeLeft = timeLeft(seconds: detail.secondsRemaining)

        var lines: [DownloadStatusLine] = []
        func add(_ parts: [String?]) {
            let line = DownloadStatusLine(percent: percent, parts: parts.compactMap { $0 })
            if !lines.contains(line), line.percent != nil || !line.parts.isEmpty {
                lines.append(line)
            }
        }
        add([bytes, speed, timeLeft])
        add([bytes, speed])
        add([bytes])
        if percent != nil { add([]) }
        return lines
    }

    /// The same information, spoken: "43 percent, 182 MB of about 420 MB,
    /// 3.1 MB per second, about 1 min left".
    static func accessibilityLabel(for detail: DownloadProgressDetail) -> String {
        var parts: [String] = []
        if let fraction = detail.display.fraction {
            parts.append(percent(fraction).replacingOccurrences(of: "%", with: " percent"))
        }
        let received = byteCount(detail.display.receivedBytes)
        if let total = detail.display.totalBytes {
            parts.append("\(received) of \(detail.display.isEstimated ? "about " : "")\(byteCount(total))")
        } else {
            parts.append("\(received) downloaded")
        }
        if let speed = detail.bytesPerSecond {
            parts.append(self.speed(speed).replacingOccurrences(of: "/s", with: " per second"))
        }
        if let timeLeft = timeLeft(seconds: detail.secondsRemaining) {
            parts.append(timeLeft)
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Row state

/// What an active download's row shows. Waiting, preparing and queued keep
/// their own wording and never show a speed or a time left.
enum DownloadRowStatus: Equatable {
    /// Downloads can't use the current network.
    case waiting(DownloadWaitReason)
    /// The task exists but no bytes have arrived (the server is starting
    /// ffmpeg): "Preparing...", not a bar stuck at 0%.
    case preparing
    case downloading(DownloadProgressDetail)
    case queued

    static func resolve(
        waitReason: DownloadWaitReason?,
        isPreparing: Bool,
        detail: DownloadProgressDetail?
    ) -> DownloadRowStatus {
        if let waitReason { return .waiting(waitReason) }
        if isPreparing { return .preparing }
        guard let detail else { return .queued }
        // Running, but nothing received and nothing to show yet.
        if detail.display.receivedBytes <= 0 { return .preparing }
        return .downloading(detail)
    }
}

// MARK: - Persistence

/// Per-record estimate inputs in UserDefaults, so a download still running
/// in the background session after a relaunch shows the same estimate.
enum DownloadEstimateStore {
    static let key = "downloadSizeEstimateInputs"

    static func all(defaults: UserDefaults = .standard) -> [String: DownloadEstimateInput] {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: DownloadEstimateInput].self, from: data) else {
            return [:]
        }
        return decoded
    }

    static func input(recordID: String, defaults: UserDefaults = .standard) -> DownloadEstimateInput? {
        all(defaults: defaults)[recordID]
    }

    static func set(_ input: DownloadEstimateInput, recordID: String, defaults: UserDefaults = .standard) {
        var entries = all(defaults: defaults)
        guard entries[recordID] != input else { return }
        entries[recordID] = input
        save(entries, defaults: defaults)
    }

    /// Called when a download finishes or is deleted, so the store doesn't
    /// grow forever.
    static func forget(recordID: String, defaults: UserDefaults = .standard) {
        var entries = all(defaults: defaults)
        guard entries.removeValue(forKey: recordID) != nil else { return }
        save(entries, defaults: defaults)
    }

    static func clearAll(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    private static func save(_ entries: [String: DownloadEstimateInput], defaults: UserDefaults) {
        guard !entries.isEmpty, let data = try? JSONEncoder().encode(entries) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
