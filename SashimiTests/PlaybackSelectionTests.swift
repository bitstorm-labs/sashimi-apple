import XCTest
@testable import Sashimi

final class PlaybackSelectionTests: XCTestCase {
    // MARK: - Helpers

    private func subtitleStream(
        language: String?,
        index: Int?,
        isDefault: Bool? = nil,
        isExternal: Bool? = nil,
        displayTitle: String? = nil
    ) -> MediaStream {
        MediaStream(
            type: "Subtitle",
            codec: "subrip",
            language: language,
            displayTitle: displayTitle ?? language,
            title: nil,
            height: nil,
            width: nil,
            channels: nil,
            index: index,
            isDefault: isDefault,
            isExternal: isExternal,
            isForced: nil,
            videoRangeType: nil,
            bitRate: nil,
            deliveryUrl: nil,
            deliveryMethod: nil
        )
    }

    // MARK: - effectiveMaxBitrate

    func testSessionOverrideWinsOverSettings() {
        XCTAssertEqual(
            PlaybackSelection.effectiveMaxBitrate(sessionOverride: 8_000_000, settingsMaxBitrate: 20_000_000),
            8_000_000
        )
    }

    func testSettingsBitrateUsedWithoutOverride() {
        XCTAssertEqual(
            PlaybackSelection.effectiveMaxBitrate(sessionOverride: nil, settingsMaxBitrate: 20_000_000),
            20_000_000
        )
    }

    func testAutoSettingsBitrateMeansNoCap() {
        XCTAssertNil(PlaybackSelection.effectiveMaxBitrate(sessionOverride: nil, settingsMaxBitrate: 0))
    }

    // MARK: - autoBitrateCap

    func testUnmeasuredLocalServerGetsOptimisticCap() {
        // The bug: a failed probe looked identical to a slow link, so a 24.9
        // Mbps 4K source on a gigabit LAN was capped at 20 Mbps and re-encoded.
        let cap = PlaybackSelection.autoBitrateCap(measuredBitrate: nil, isLocalServer: true)
        XCTAssertEqual(cap, PlaybackSelection.unmeasuredLocalBitrateCap)
        XCTAssertGreaterThan(cap, 24_879_906)
    }

    func testUnmeasuredRemoteServerStaysConservative() {
        XCTAssertEqual(
            PlaybackSelection.autoBitrateCap(measuredBitrate: nil, isLocalServer: false),
            PlaybackSelection.unmeasuredRemoteBitrateCap
        )
    }

    func testMeasuredBitrateKeepsHeadroom() {
        XCTAssertEqual(
            PlaybackSelection.autoBitrateCap(measuredBitrate: 40_000_000, isLocalServer: true),
            34_000_000
        )
    }

    func testMeasuredSlowLinkIsHonoredOnALocalServer() {
        // A measurement is evidence; a LAN server does not override it.
        XCTAssertEqual(
            PlaybackSelection.autoBitrateCap(measuredBitrate: 10_000_000, isLocalServer: true),
            8_500_000
        )
    }

    func testMeasuredBitrateIsClampedBothWays() {
        XCTAssertEqual(
            PlaybackSelection.autoBitrateCap(measuredBitrate: 500_000, isLocalServer: false),
            PlaybackSelection.minimumMeasuredBitrateCap
        )
        XCTAssertEqual(
            PlaybackSelection.autoBitrateCap(measuredBitrate: 1_000_000_000, isLocalServer: false),
            PlaybackSelection.maximumMeasuredBitrateCap
        )
    }

    func testNonPositiveMeasurementIsTreatedAsNoMeasurement() {
        XCTAssertEqual(
            PlaybackSelection.autoBitrateCap(measuredBitrate: 0, isLocalServer: true),
            PlaybackSelection.unmeasuredLocalBitrateCap
        )
    }

    // MARK: - autoMaxWidth

    func testHighCapDoesNotConstrainWidth() {
        // 4K must stay 4K when the link can carry it — this is the path a LAN
        // client takes, and it must not start downscaling.
        XCTAssertNil(PlaybackSelection.autoMaxWidth(forBitrateCap: 100_000_000))
        XCTAssertNil(PlaybackSelection.autoMaxWidth(forBitrateCap: 25_000_000))
    }

    func testLowCapsPickAResolutionTheCapCanCarry() {
        // Without a width the server re-encodes at source resolution, so a
        // capped 4K stream was re-encoded at full 4K.
        XCTAssertEqual(PlaybackSelection.autoMaxWidth(forBitrateCap: 20_000_000), 1920)
        XCTAssertEqual(PlaybackSelection.autoMaxWidth(forBitrateCap: 8_000_000), 1280)
        XCTAssertEqual(PlaybackSelection.autoMaxWidth(forBitrateCap: 3_000_000), 854)
    }

    // MARK: - constrainedAutoOverride

    func testConstrainedLinkKeeps4KAtSmoothBitrate() {
        // The bedroom Wi-Fi case: cap ~61 Mbps under a 68.8 Mbps 4K remux. Keep
        // 4K (like Roku) but cap the transcode to a light, smooth bitrate — a
        // 66 Mbps 4K re-encode OOMs/stutters.
        let override = PlaybackSelection.constrainedAutoOverride(cap: 61_000_000, sourceBitrate: 68_818_483, isWired: false)
        XCTAssertEqual(override?.maxWidth, 3840)
        XCTAssertEqual(override?.maxBitrate, PlaybackSelection.smooth4KBitrate)
    }

    func testConstrainedBitrateNeverExceedsTheCap() {
        // A mid Wi-Fi link under both the source and the smooth-4K ceiling keeps
        // 4K but is capped to the link.
        let override = PlaybackSelection.constrainedAutoOverride(cap: 18_000_000, sourceBitrate: 40_000_000, isWired: false)
        XCTAssertEqual(override?.maxWidth, 3840)
        XCTAssertEqual(override?.maxBitrate, 18_000_000)
    }

    func testSlowLinkDropsTo1080p() {
        // Below the 4K floor a 4K encode would be blocky, so spend the bits on
        // 1080p instead.
        let override = PlaybackSelection.constrainedAutoOverride(cap: 9_000_000, sourceBitrate: 40_000_000, isWired: false)
        XCTAssertEqual(override?.maxWidth, 1920)
        XCTAssertEqual(override?.maxBitrate, 8_000_000)
    }

    func testWirelessNeverCopiesHeavy4KEvenWhenProbeReadsHigh() {
        // The Living Room bug: the burst probe over-reads Wi-Fi's peak (here
        // 90 Mbps) above the 68.8 Mbps source, so the old rule (cap >= source)
        // let the server copy it — and Wi-Fi stalled on the VBR peaks. The
        // wireless ceiling now forces a smooth 24 Mbps 4K transcode instead.
        let override = PlaybackSelection.constrainedAutoOverride(cap: 90_000_000, sourceBitrate: 68_818_483, isWired: false)
        XCTAssertEqual(override?.maxWidth, 3840)
        XCTAssertEqual(override?.maxBitrate, PlaybackSelection.smooth4KBitrate)
    }

    func testWiredCopiesHeavy4KNatively() {
        // Ethernet can carry what it measured, so a heavy 4K source above the
        // smooth ceiling is left untouched and stream-copied native.
        XCTAssertNil(PlaybackSelection.constrainedAutoOverride(cap: 90_000_000, sourceBitrate: 68_818_483, isWired: true))
        XCTAssertNil(PlaybackSelection.constrainedAutoOverride(cap: 68_818_483, sourceBitrate: 68_818_483, isWired: true))
    }

    func testWirelessSafeSourceIsNotConstrained() {
        // A source already under the smooth-4K ceiling is Wi-Fi-safe: copy it
        // untouched rather than pointlessly transcoding.
        XCTAssertNil(PlaybackSelection.constrainedAutoOverride(cap: 30_000_000, sourceBitrate: 20_000_000, isWired: false))
    }

    func testUnknownSourceBitrateIsNotConstrained() {
        XCTAssertNil(PlaybackSelection.constrainedAutoOverride(cap: 20_000_000, sourceBitrate: nil, isWired: false))
        XCTAssertNil(PlaybackSelection.constrainedAutoOverride(cap: 20_000_000, sourceBitrate: 0, isWired: true))
    }

    // MARK: - isLocalServer

    func testPrivateAddressesAreLocal() {
        for host in ["192.168.86.151", "10.0.0.5", "172.16.4.2", "172.31.255.254", "127.0.0.1", "169.254.1.1"] {
            XCTAssertTrue(
                PlaybackSelection.isLocalServer(URL(string: "http://\(host):8096")),
                "\(host) should be treated as local"
            )
        }
    }

    func testLocalNamesAreLocal() {
        XCTAssertTrue(PlaybackSelection.isLocalServer(URL(string: "http://localhost:8096")))
        XCTAssertTrue(PlaybackSelection.isLocalServer(URL(string: "http://popcorn.local:8096")))
        XCTAssertTrue(PlaybackSelection.isLocalServer(URL(string: "http://popcorn:8096")))
        XCTAssertTrue(PlaybackSelection.isLocalServer(URL(string: "http://[::1]:8096")))
        XCTAssertTrue(PlaybackSelection.isLocalServer(URL(string: "http://[fd00::1]:8096")))
    }

    func testPublicAddressesAreNotLocal() {
        for host in ["jellyfin.example.com", "8.8.8.8", "172.32.0.1", "192.169.0.1", "fc.example.com"] {
            XCTAssertFalse(
                PlaybackSelection.isLocalServer(URL(string: "https://\(host)")),
                "\(host) should be treated as remote"
            )
        }
        XCTAssertFalse(PlaybackSelection.isLocalServer(nil))
    }

    // MARK: - languagesMatch

    func testMatchesIso639TwoVsThreeLetterCodes() {
        XCTAssertTrue(PlaybackSelection.languagesMatch("eng", "en"))
        XCTAssertTrue(PlaybackSelection.languagesMatch("en", "eng"))
        XCTAssertTrue(PlaybackSelection.languagesMatch("spa", "es"))
        XCTAssertTrue(PlaybackSelection.languagesMatch("fra", "fr"))
        XCTAssertTrue(PlaybackSelection.languagesMatch("jpn", "ja"))
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertTrue(PlaybackSelection.languagesMatch("ENG", "en"))
        XCTAssertTrue(PlaybackSelection.languagesMatch("En", "eN"))
    }

    func testDifferentLanguagesDoNotMatch() {
        XCTAssertFalse(PlaybackSelection.languagesMatch("eng", "es"))
        XCTAssertFalse(PlaybackSelection.languagesMatch("fra", "de"))
    }

    func testNilOrEmptyCodesNeverMatch() {
        XCTAssertFalse(PlaybackSelection.languagesMatch(nil, "en"))
        XCTAssertFalse(PlaybackSelection.languagesMatch("en", nil))
        XCTAssertFalse(PlaybackSelection.languagesMatch(nil, nil))
        XCTAssertFalse(PlaybackSelection.languagesMatch("", "en"))
        XCTAssertFalse(PlaybackSelection.languagesMatch("en", ""))
    }

    func testUnmappableCodesFallBackToLiteralComparison() {
        XCTAssertTrue(PlaybackSelection.languagesMatch("und", "UND"))
        XCTAssertFalse(PlaybackSelection.languagesMatch("und", "en"))
    }

    // MARK: - preferredSubtitleStream

    func testNoSubtitleWhenDisabled() {
        let streams = [subtitleStream(language: "eng", index: 1, isDefault: true)]
        XCTAssertNil(
            PlaybackSelection.preferredSubtitleStream(from: streams, preferredLanguage: "en", subtitlesEnabled: false)
        )
    }

    func testNoSubtitleWhenNoStreams() {
        XCTAssertNil(
            PlaybackSelection.preferredSubtitleStream(from: [], preferredLanguage: "en", subtitlesEnabled: true)
        )
    }

    func testPreferredLanguageWinsOverDefaultFlag() {
        let streams = [
            subtitleStream(language: "fre", index: 1, isDefault: true),
            subtitleStream(language: "eng", index: 2)
        ]
        let selected = PlaybackSelection.preferredSubtitleStream(
            from: streams,
            preferredLanguage: "en",
            subtitlesEnabled: true
        )
        XCTAssertEqual(selected?.index, 2)
    }

    func testFallsBackToDefaultFlaggedStreamWhenLanguageUnavailable() {
        let streams = [
            subtitleStream(language: "fre", index: 1),
            subtitleStream(language: "ger", index: 2, isDefault: true)
        ]
        let selected = PlaybackSelection.preferredSubtitleStream(
            from: streams,
            preferredLanguage: "ja",
            subtitlesEnabled: true
        )
        XCTAssertEqual(selected?.index, 2)
    }

    func testFallsBackToFirstStreamWithoutDefaultFlag() {
        let streams = [
            subtitleStream(language: "fre", index: 3),
            subtitleStream(language: "ger", index: 4)
        ]
        let selected = PlaybackSelection.preferredSubtitleStream(
            from: streams,
            preferredLanguage: "",
            subtitlesEnabled: true
        )
        XCTAssertEqual(selected?.index, 3)
    }

    // MARK: - matchingSubtitleStream

    func testMatchesByLanguageWhenIndexesShift() {
        // Same track, but the new media source numbers its streams differently
        let streams = [
            subtitleStream(language: "fre", index: 4),
            subtitleStream(language: "eng", index: 7)
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "eng",
            displayTitle: "eng",
            isExternal: false
        )
        XCTAssertEqual(match?.index, 7)
    }

    func testMatchesToleratesTwoVsThreeLetterLanguageCodes() {
        let streams = [subtitleStream(language: "eng", index: 3)]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "en",
            displayTitle: nil,
            isExternal: false
        )
        XCTAssertEqual(match?.index, 3)
    }

    func testPrefersDisplayTitleMatchAmongSameLanguageStreams() {
        let streams = [
            subtitleStream(language: "eng", index: 2, displayTitle: "English"),
            subtitleStream(language: "eng", index: 3, displayTitle: "English (SDH)")
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "eng",
            displayTitle: "English (SDH)",
            isExternal: false
        )
        XCTAssertEqual(match?.index, 3)
    }

    func testPrefersMatchingExternalFlagWhenTitleDiffers() {
        let streams = [
            subtitleStream(language: "eng", index: 2, isExternal: false, displayTitle: "English (embedded)"),
            subtitleStream(language: "eng", index: 5, isExternal: true, displayTitle: "English (SRT)")
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "eng",
            displayTitle: "English",
            isExternal: true
        )
        XCTAssertEqual(match?.index, 5)
    }

    func testFallsBackToLanguageOnlyWhenExternalFlagDiffers() {
        let streams = [
            subtitleStream(language: "eng", index: 2, isExternal: false, displayTitle: "English")
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "eng",
            displayTitle: "English (SRT)",
            isExternal: true
        )
        XCTAssertEqual(match?.index, 2)
    }

    func testSkipsStreamsWithoutAnIndex() {
        // A stream with no index can't be addressed for playback — matching
        // it would previously collapse to index 0 and silently fail.
        let streams = [
            subtitleStream(language: "eng", index: nil),
            subtitleStream(language: "eng", index: 6)
        ]
        let match = PlaybackSelection.matchingSubtitleStream(
            in: streams,
            language: "eng",
            displayTitle: "eng",
            isExternal: false
        )
        XCTAssertEqual(match?.index, 6)
    }

    func testNoMatchWhenLanguageMissingFromNewSource() {
        let streams = [subtitleStream(language: "fre", index: 1)]
        XCTAssertNil(
            PlaybackSelection.matchingSubtitleStream(
                in: streams,
                language: "eng",
                displayTitle: "eng",
                isExternal: false
            )
        )
    }

    func testNoMatchForNilLanguagePreference() {
        let streams = [subtitleStream(language: "eng", index: 1)]
        XCTAssertNil(
            PlaybackSelection.matchingSubtitleStream(
                in: streams,
                language: nil,
                displayTitle: "Unknown",
                isExternal: false
            )
        )
    }

    // MARK: - preferredAudioOptionIndex

    func testAudioIndexMatchesPreferredLanguage() {
        // AVFoundation reports two-letter codes; the setting stores two-letter too
        let codes: [String?] = ["ja", "en", "es"]
        XCTAssertEqual(PlaybackSelection.preferredAudioOptionIndex(languageCodes: codes, preferredLanguage: "en"), 1)
    }

    func testAudioIndexNilWithoutPreference() {
        XCTAssertNil(PlaybackSelection.preferredAudioOptionIndex(languageCodes: ["en"], preferredLanguage: ""))
    }

    func testAudioIndexNilWhenNoMatch() {
        let codes: [String?] = ["ja", nil, "es"]
        XCTAssertNil(PlaybackSelection.preferredAudioOptionIndex(languageCodes: codes, preferredLanguage: "de"))
    }
}
