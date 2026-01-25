import SwiftUI
import AVFoundation

// MARK: - WebVTT Parser

struct SubtitleCue: Identifiable {
    let id = UUID()
    let startTime: Double
    let endTime: Double
    let text: String
}

@MainActor
class SubtitleManager: ObservableObject {
    @Published var currentCue: SubtitleCue?
    @Published var isLoading = false

    private var cues: [SubtitleCue] = []
    private var timeObserver: Any?
    private weak var player: AVPlayer?

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
            let (data, _) = try await URLSession.shared.data(for: request)
            if let vttContent = String(data: data, encoding: .utf8) {
                cues = parseWebVTT(vttContent)
            }
        } catch {
            // Silently fail - no subtitles
        }

        isLoading = false
    }

    func clear() {
        stopTracking()
        cues = []
        currentCue = nil
    }

    func startTracking(player: AVPlayer) {
        self.player = player
        stopTracking()

        let interval = CMTime(seconds: 0.1, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            self?.updateCurrentCue(at: time.seconds)
        }
    }

    func stopTracking() {
        if let observer = timeObserver, let player = player {
            player.removeTimeObserver(observer)
        }
        timeObserver = nil
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
                            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) // Remove tags
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

// MARK: - Subtitle Overlay View

struct SubtitleOverlay: View {
    @ObservedObject var manager: SubtitleManager

    var body: some View {
        VStack {
            Spacer()

            if let cue = manager.currentCue {
                Text(cue.text)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(
                        Color.black.opacity(0.75)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.bottom, 80)
                    .transition(.opacity)
                    .id(cue.id)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: manager.currentCue?.id)
        .allowsHitTesting(false)
    }
}
