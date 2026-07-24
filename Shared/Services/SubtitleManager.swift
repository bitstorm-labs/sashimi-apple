import SwiftUI
import AVFoundation
import os

private let logger = Logger(subsystem: "com.mondominator.sashimi", category: "SubtitleManager")

// MARK: - Subtitle Cue

struct SubtitleCue: Identifiable {
    let id = UUID()
    let startTime: Double
    let endTime: Double
    let text: String
}

// MARK: - Subtitle Manager

@MainActor
class SubtitleManager: ObservableObject {
    @Published var currentCue: SubtitleCue?
    @Published var isLoading = false

    private var cues: [SubtitleCue] = []
    // The observer token is stored together with a strong reference to the
    // player it was created on: removeTimeObserver must be called on that
    // exact player (calling it on a different player throws
    // NSInvalidArgumentException, and letting the player dealloc with a live
    // observer throws NSInternalInconsistencyException).
    private var timeObservation: (token: Any, player: AVPlayer)?

    func loadSubtitles(itemId: String, subtitleIndex: Int) async {
        isLoading = true
        currentCue = nil
        cues = []

        guard let serverURL = UserDefaults.standard.string(forKey: "serverURL"),
              let accessToken = KeychainHelper.get(forKey: "accessToken") else {
            isLoading = false
            return
        }

        // Build subtitle URL
        let urlString = "\(serverURL)/Videos/\(itemId)/\(itemId)/Subtitles/\(subtitleIndex)/Stream.vtt"

        guard let url = URL(string: urlString) else {
            isLoading = false
            return
        }

        // Use header for authentication instead of query parameter
        var request = URLRequest(url: url)
        request.setValue(accessToken, forHTTPHeaderField: "X-Emby-Token")

        do {
            let session = await JellyfinClient.shared.urlSession
            let (data, _) = try await session.data(for: request)
            if let vttContent = String(data: data, encoding: .utf8) {
                cues = parseWebVTT(vttContent)
            }
        } catch {
            // Subtitle loading failed — no subtitles will be shown
            logger.error("Failed to load subtitles for item \(itemId, privacy: .public) index \(subtitleIndex): \(error.localizedDescription, privacy: .public)")
        }

        isLoading = false
    }

    func clear() {
        stopTracking()
        cues = []
        currentCue = nil
    }

    func startTracking(player: AVPlayer) {
        // Remove any observer from the previous player FIRST — tearing down
        // after switching players would pair the old token with the new
        // player and crash (see timeObservation).
        stopTracking()

        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        let token = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateCurrentCue(at: time.seconds)
        }
        timeObservation = (token: token, player: player)
    }

    func stopTracking() {
        if let observation = timeObservation {
            observation.player.removeTimeObserver(observation.token)
        }
        timeObservation = nil
    }

    deinit {
        // Safety net: the tuple holds the last strong reference to the
        // player, so dropping it with a live observer would dealloc the
        // player mid-observation and crash. Normal teardown goes through
        // clear()/stopTracking() before this ever matters.
        if let observation = timeObservation {
            observation.player.removeTimeObserver(observation.token)
        }
    }

    private func updateCurrentCue(at time: Double) {
        let activeCue = cues.first { cue in
            time >= cue.startTime && time < cue.endTime
        }

        if activeCue?.id != currentCue?.id {
            currentCue = activeCue
        }
    }

    private func parseWebVTT(_ content: String) -> [SubtitleCue] {
        var result: [SubtitleCue] = []
        let lines = content.components(separatedBy: .newlines)

        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)

            // Look for timestamp line (contains "-->")
            if line.contains("-->") {
                let times = parseTimestampLine(line)
                if let (start, end) = times {
                    // Collect text lines until empty line
                    var textLines: [String] = []
                    i += 1
                    while i < lines.count && !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                        let textLine = lines[i]
                            .trimmingCharacters(in: .whitespaces)
                            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                            // ASS/SSA override blocks ride along when SRT subs
                            // with embedded styling get converted to VTT (e.g.
                            // "{\an8}" = position top-center) — Jellyfin passes
                            // them through verbatim and they rendered as literal
                            // text at the start of lines. Strip any "{\...}".
                            .replacingOccurrences(of: "\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
                            .trimmingCharacters(in: .whitespaces)
                        if !textLine.isEmpty {
                            textLines.append(textLine)
                        }
                        i += 1
                    }

                    if !textLines.isEmpty {
                        result.append(SubtitleCue(
                            startTime: start,
                            endTime: end,
                            text: textLines.joined(separator: "\n")
                        ))
                    }
                }
            }
            i += 1
        }

        return result
    }

    private func parseTimestampLine(_ line: String) -> (Double, Double)? {
        // Format: "00:00:02.294 --> 00:00:04.046 region:subtitle line:90%"
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
        let endStr = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""

        guard let start = parseTimestamp(startStr),
              let end = parseTimestamp(endStr) else { return nil }

        return (start, end)
    }

    private func parseTimestamp(_ str: String) -> Double? {
        // Format: "00:00:02.294" or "00:02.294"
        let parts = str.components(separatedBy: ":")
        guard parts.count >= 2 else { return nil }

        var seconds: Double = 0

        if parts.count == 3 {
            // HH:MM:SS.mmm
            seconds += (Double(parts[0]) ?? 0) * 3600
            seconds += (Double(parts[1]) ?? 0) * 60
            seconds += Double(parts[2]) ?? 0
        } else {
            // MM:SS.mmm
            seconds += (Double(parts[0]) ?? 0) * 60
            seconds += Double(parts[1]) ?? 0
        }

        return seconds
    }
}
