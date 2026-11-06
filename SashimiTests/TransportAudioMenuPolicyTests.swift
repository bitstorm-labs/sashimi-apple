import XCTest
@testable import Sashimi

/// The tvOS transport bar's Audio menu: on a transcode the native AVKit
/// Audio tab sees only the one mapped track, so ours must be there.
final class TransportAudioMenuPolicyTests: XCTestCase {
    func testTranscodeWithSeveralTracksGetsOurAudioMenu() {
        // Love is Blind S11E09: Portuguese dub default + English, transcoded.
        XCTAssertTrue(TransportAudioMenuPolicy.includesAudioMenu(
            usesServerSideAudioSelection: true, audioTrackCount: 2
        ))
    }

    func testDirectPlayLeavesAudioToTheNativeTab() {
        XCTAssertFalse(TransportAudioMenuPolicy.includesAudioMenu(
            usesServerSideAudioSelection: false, audioTrackCount: 2
        ))
    }

    func testSingleTrackTranscodeHasNothingToSwitch() {
        XCTAssertFalse(TransportAudioMenuPolicy.includesAudioMenu(
            usesServerSideAudioSelection: true, audioTrackCount: 1
        ))
    }

    func testTracksNotLoadedYetShowNoEmptyMenu() {
        XCTAssertFalse(TransportAudioMenuPolicy.includesAudioMenu(
            usesServerSideAudioSelection: true, audioTrackCount: 0
        ))
    }
}
