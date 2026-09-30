import Foundation
import AVKit
import AVFoundation

extension PlayerViewModel {
    // MARK: - Chapter Navigation

    func setupChapterMarkers(on playerItem: AVPlayerItem, chapters: [ChapterInfo], duration: Double) {
        #if os(tvOS)
        guard !chapters.isEmpty else { return }

        var timedGroups: [AVTimedMetadataGroup] = []

        for (index, chapter) in chapters.enumerated() {
            // Create title metadata
            let titleItem = AVMutableMetadataItem()
            titleItem.key = AVMetadataKey.commonKeyTitle as NSString
            titleItem.keySpace = .common
            titleItem.value = (chapter.name ?? "Chapter \(index + 1)") as NSString

            // Calculate time range (from this chapter to next, or to end)
            let startTime = CMTime(seconds: chapter.startSeconds, preferredTimescale: 600)
            let endTime: CMTime
            if index + 1 < chapters.count {
                endTime = CMTime(seconds: chapters[index + 1].startSeconds, preferredTimescale: 600)
            } else {
                endTime = CMTime(seconds: duration, preferredTimescale: 600)
            }
            let timeRange = CMTimeRange(start: startTime, end: endTime)

            let group = AVTimedMetadataGroup(items: [titleItem], timeRange: timeRange)
            timedGroups.append(group)
        }

        // nil title = chapter markers (vs event markers)
        let markerGroup = AVNavigationMarkersGroup(title: nil, timedNavigationMarkers: timedGroups)
        playerItem.navigationMarkerGroups = [markerGroup]
        #else
        // Chapter markers are tvOS-only; iOS uses AVPlayerViewController's built-in chapter UI
        _ = (playerItem, chapters, duration)
        #endif
    }
}
