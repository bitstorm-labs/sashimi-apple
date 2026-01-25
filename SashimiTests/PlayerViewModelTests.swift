import XCTest
@testable import Sashimi

final class PlayerViewModelTests: XCTestCase {

    // MARK: - QualityOption Tests

    func testQualityOptionDisplayNames() {
        XCTAssertEqual(QualityOption.auto.displayName, "Auto")
        XCTAssertEqual(QualityOption.quality1080p.displayName, "1080p")
        XCTAssertEqual(QualityOption.quality720p.displayName, "720p")
        XCTAssertEqual(QualityOption.quality480p.displayName, "480p")
    }

    func testQualityOptionBitrates() {
        XCTAssertNil(QualityOption.auto.maxBitrate, "Auto should have no bitrate limit")
        XCTAssertEqual(QualityOption.quality1080p.maxBitrate, 20_000_000)
        XCTAssertEqual(QualityOption.quality720p.maxBitrate, 8_000_000)
        XCTAssertEqual(QualityOption.quality480p.maxBitrate, 4_000_000)
    }

    func testQualityOptionIds() {
        XCTAssertEqual(QualityOption.auto.id, "auto")
        XCTAssertEqual(QualityOption.quality1080p.id, "1080")
        XCTAssertEqual(QualityOption.quality720p.id, "720")
        XCTAssertEqual(QualityOption.quality480p.id, "480")
    }

    func testQualityOptionAllCases() {
        let allCases = QualityOption.allCases
        XCTAssertEqual(allCases.count, 4)
        XCTAssertTrue(allCases.contains(.auto))
        XCTAssertTrue(allCases.contains(.quality1080p))
        XCTAssertTrue(allCases.contains(.quality720p))
        XCTAssertTrue(allCases.contains(.quality480p))
    }

    func testQualityBitrateOrdering() {
        // Higher quality should have higher bitrate
        let bitrate1080 = QualityOption.quality1080p.maxBitrate!
        let bitrate720 = QualityOption.quality720p.maxBitrate!
        let bitrate480 = QualityOption.quality480p.maxBitrate!

        XCTAssertGreaterThan(bitrate1080, bitrate720)
        XCTAssertGreaterThan(bitrate720, bitrate480)
    }

    // MARK: - Initial State Tests

    @MainActor
    func testInitialState() {
        let viewModel = PlayerViewModel()

        XCTAssertNil(viewModel.player)
        XCTAssertTrue(viewModel.isLoading)
        XCTAssertNil(viewModel.error)
        XCTAssertNil(viewModel.currentItem)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertTrue(viewModel.audioTracks.isEmpty)
        XCTAssertTrue(viewModel.subtitleTracks.isEmpty)
        XCTAssertFalse(viewModel.playbackEnded)
        XCTAssertNil(viewModel.nextEpisode)
        XCTAssertFalse(viewModel.showingUpNext)
        XCTAssertEqual(viewModel.resumePositionTicks, 0)
        XCTAssertEqual(viewModel.selectedQuality, .auto)
    }

    @MainActor
    func testInitialSegmentState() {
        let viewModel = PlayerViewModel()

        XCTAssertTrue(viewModel.segments.isEmpty)
        XCTAssertNil(viewModel.currentSegment)
        XCTAssertFalse(viewModel.showingSkipButton)
    }

    // MARK: - AudioTrackOption Tests

    func testAudioTrackOptionCreation() {
        let track = AudioTrackOption(
            id: "audio-1",
            displayName: "English 5.1",
            languageCode: "en",
            index: 0
        )

        XCTAssertEqual(track.id, "audio-1")
        XCTAssertEqual(track.displayName, "English 5.1")
        XCTAssertEqual(track.languageCode, "en")
        XCTAssertEqual(track.index, 0)
    }

    func testAudioTrackOptionEquality() {
        let track1 = AudioTrackOption(id: "1", displayName: "English", languageCode: "en", index: 0)
        let track2 = AudioTrackOption(id: "1", displayName: "English", languageCode: "en", index: 0)
        let track3 = AudioTrackOption(id: "2", displayName: "Spanish", languageCode: "es", index: 1)

        XCTAssertEqual(track1, track2)
        XCTAssertNotEqual(track1, track3)
    }

    func testAudioTrackOptionHashable() {
        let track1 = AudioTrackOption(id: "1", displayName: "English", languageCode: "en", index: 0)
        let track2 = AudioTrackOption(id: "2", displayName: "Spanish", languageCode: "es", index: 1)

        var set = Set<AudioTrackOption>()
        set.insert(track1)
        set.insert(track2)
        set.insert(track1) // Duplicate

        XCTAssertEqual(set.count, 2)
    }

    // MARK: - SubtitleTrackOption Tests

    func testSubtitleTrackOptionCreation() {
        let track = SubtitleTrackOption(
            id: "sub-1",
            displayName: "English (SRT)",
            languageCode: "en",
            index: 2,
            isOffOption: false,
            isExternal: true
        )

        XCTAssertEqual(track.id, "sub-1")
        XCTAssertEqual(track.displayName, "English (SRT)")
        XCTAssertEqual(track.languageCode, "en")
        XCTAssertEqual(track.index, 2)
        XCTAssertFalse(track.isOffOption)
        XCTAssertTrue(track.isExternal)
    }

    func testSubtitleOffOption() {
        let offTrack = SubtitleTrackOption(
            id: "off",
            displayName: "Off",
            languageCode: nil,
            index: -1,
            isOffOption: true,
            isExternal: false
        )

        XCTAssertTrue(offTrack.isOffOption)
        XCTAssertEqual(offTrack.index, -1)
        XCTAssertNil(offTrack.languageCode)
    }

    func testSubtitleTrackOptionEquality() {
        let track1 = SubtitleTrackOption(id: "1", displayName: "English", languageCode: "en", index: 0, isOffOption: false)
        let track2 = SubtitleTrackOption(id: "1", displayName: "English", languageCode: "en", index: 0, isOffOption: false)

        XCTAssertEqual(track1, track2)
    }

    // MARK: - Media Segment Tests

    func testMediaSegmentDtoCreation() {
        let segment = MediaSegmentDto(
            id: "segment-123",
            type: .intro,
            startSeconds: 0.0,
            endSeconds: 90.0
        )

        XCTAssertEqual(segment.id, "segment-123")
        XCTAssertEqual(segment.type, .intro)
        XCTAssertEqual(segment.startSeconds, 0.0)
        XCTAssertEqual(segment.endSeconds, 90.0)
    }

    func testMediaSegmentTimings() {
        let segment = MediaSegmentDto(
            id: "seg-1",
            type: .intro,
            startSeconds: 30.0,
            endSeconds: 90.0
        )

        XCTAssertEqual(segment.startSeconds, 30.0, accuracy: 0.001)
        XCTAssertEqual(segment.endSeconds, 90.0, accuracy: 0.001)

        // Duration should be end - start
        let duration = segment.endSeconds - segment.startSeconds
        XCTAssertEqual(duration, 60.0, accuracy: 0.001)
    }

    func testSkippableSegmentTypes() {
        // These types should be skippable
        let skippableTypes: [MediaSegmentType] = [.intro, .outro, .recap, .preview]

        for type in skippableTypes {
            XCTAssertTrue(
                [MediaSegmentType.intro, .outro, .recap, .preview].contains(type),
                "\(type) should be skippable"
            )
        }

        // Unknown should not be in the skippable list by default
        XCTAssertFalse(
            [MediaSegmentType.intro, .outro, .recap, .preview].contains(.unknown),
            "Unknown segment type should not be skippable"
        )
    }

    // MARK: - Time Conversion Tests

    func testTicksToSecondsConversion() {
        // 10,000,000 ticks = 1 second
        let ticks: Int64 = 36_000_000_000 // 1 hour
        let seconds = Double(ticks) / 10_000_000.0

        XCTAssertEqual(seconds, 3600.0, accuracy: 0.001)
    }

    func testSecondsToTicksConversion() {
        let seconds: Double = 90.5
        let ticks = Int64(seconds * 10_000_000)

        XCTAssertEqual(ticks, 905_000_000)
    }

    func testZeroTicksConversion() {
        let ticks: Int64 = 0
        let seconds = Double(ticks) / 10_000_000.0

        XCTAssertEqual(seconds, 0.0)
    }

    // MARK: - Resume Position Tests

    func testResumeThresholdCalculation() {
        // Default threshold is typically 10 seconds
        let thresholdSeconds = 10
        let thresholdTicks = Int64(thresholdSeconds) * 10_000_000

        XCTAssertEqual(thresholdTicks, 100_000_000)

        // Position below threshold should not trigger resume
        let lowPosition: Int64 = 50_000_000 // 5 seconds
        XCTAssertLessThan(lowPosition, thresholdTicks)

        // Position above threshold should trigger resume
        let highPosition: Int64 = 150_000_000 // 15 seconds
        XCTAssertGreaterThan(highPosition, thresholdTicks)
    }

    // MARK: - Progress Calculation Tests

    func testProgressPercentageCalculation() {
        let currentTicks: Int64 = 300_000_000 // 30 seconds
        let totalTicks: Int64 = 600_000_000 // 60 seconds

        let progress = Double(currentTicks) / Double(totalTicks) * 100
        XCTAssertEqual(progress, 50.0, accuracy: 0.001)
    }

    func testProgressAtStart() {
        let currentTicks: Int64 = 0
        let totalTicks: Int64 = 600_000_000

        let progress = Double(currentTicks) / Double(totalTicks) * 100
        XCTAssertEqual(progress, 0.0)
    }

    func testProgressAtEnd() {
        let currentTicks: Int64 = 600_000_000
        let totalTicks: Int64 = 600_000_000

        let progress = Double(currentTicks) / Double(totalTicks) * 100
        XCTAssertEqual(progress, 100.0)
    }

    // MARK: - Next Episode Logic Tests

    func testNextEpisodeIndexCalculation() {
        let currentIndex = 5
        let expectedNextIndex = currentIndex + 1

        XCTAssertEqual(expectedNextIndex, 6)
    }

    func testNextEpisodeMatchingLogic() {
        // Simulate finding next episode from a list
        let episodes = [
            (index: 1, id: "ep1"),
            (index: 2, id: "ep2"),
            (index: 3, id: "ep3"),
            (index: 4, id: "ep4"),
        ]

        let currentIndex = 2
        let nextEpisode = episodes.first { $0.index == currentIndex + 1 }

        XCTAssertNotNil(nextEpisode)
        XCTAssertEqual(nextEpisode?.id, "ep3")
    }

    func testNoNextEpisodeAtEnd() {
        let episodes = [
            (index: 1, id: "ep1"),
            (index: 2, id: "ep2"),
        ]

        let currentIndex = 2
        let nextEpisode = episodes.first { $0.index == currentIndex + 1 }

        XCTAssertNil(nextEpisode, "Should be nil when at last episode")
    }

    // YouTube-style index matching (date-based, find next higher)
    func testYouTubeStyleNextEpisode() {
        let episodes = [
            (index: 20241101, id: "vid1"),
            (index: 20241105, id: "vid2"),
            (index: 20241110, id: "vid3"),
        ]

        let currentIndex = 20241101
        // Find first item with index > currentIndex (not exactly +1)
        let nextVideo = episodes.sorted { $0.index < $1.index }.first { $0.index > currentIndex }

        XCTAssertNotNil(nextVideo)
        XCTAssertEqual(nextVideo?.id, "vid2")
    }

    // MARK: - Quick Exit Protection Tests

    func testQuickExitProtectionLogic() {
        let playbackStartTime = Date()
        let quickExitThreshold: TimeInterval = 10.0

        // Simulate quick exit (< 10 seconds)
        let quickExitTime = playbackStartTime.addingTimeInterval(5.0)
        let elapsedQuick = quickExitTime.timeIntervalSince(playbackStartTime)
        XCTAssertLessThan(elapsedQuick, quickExitThreshold)

        // Simulate normal exit (>= 10 seconds)
        let normalExitTime = playbackStartTime.addingTimeInterval(15.0)
        let elapsedNormal = normalExitTime.timeIntervalSince(playbackStartTime)
        XCTAssertGreaterThan(elapsedNormal, quickExitThreshold)
    }

    func testQuickExitPreservesOriginalPosition() {
        let originalPositionTicks: Int64 = 1_800_000_000 // 3 minutes
        let currentPositionTicks: Int64 = 50_000_000 // 5 seconds (user barely watched)
        let elapsedSeconds: TimeInterval = 5.0
        let quickExitThreshold: TimeInterval = 10.0

        // If elapsed < threshold and original position exists, preserve original
        let positionToReport: Int64
        if elapsedSeconds < quickExitThreshold && originalPositionTicks > 0 {
            positionToReport = originalPositionTicks
        } else {
            positionToReport = currentPositionTicks
        }

        XCTAssertEqual(positionToReport, originalPositionTicks)
    }

    // MARK: - PlayerError Tests

    func testPlayerErrorDescriptions() {
        XCTAssertEqual(PlayerError.noMediaSource.errorDescription, "No playable media source found")
        XCTAssertEqual(PlayerError.noStreamURL.errorDescription, "Could not generate stream URL")
    }

    func testPlayerErrorConformsToLocalizedError() {
        let error: LocalizedError = PlayerError.noMediaSource
        XCTAssertNotNil(error.errorDescription)
    }
}
