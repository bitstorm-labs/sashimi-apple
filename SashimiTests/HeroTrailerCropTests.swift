import XCTest
@testable import Sashimi

/// A letterboxed trailer put a black band across the top of the detail hero
/// while it played, so the picture looked pushed down from the screen's top
/// edge (Roku and the still image are flush). The bars are now measured off
/// the decoded frames and cropped away with the overflow.
final class HeroTrailerCropTests: XCTestCase {
    private let width = 1920
    private let height = 1080

    /// A luma plane: `bright` everywhere except rows/columns set to black.
    private func frame(
        blackTop: Int = 0, blackBottom: Int = 0, blackLeft: Int = 0, blackRight: Int = 0,
        bright: UInt8 = 120, black: UInt8 = 16, padding: Int = 0
    ) -> (pixels: [UInt8], bytesPerRow: Int) {
        let bytesPerRow = width + padding
        var pixels = [UInt8](repeating: bright, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width {
                let inBar = y < blackTop || y >= height - blackBottom || x < blackLeft || x >= width - blackRight
                if inBar { pixels[y * bytesPerRow + x] = black }
            }
        }
        return (pixels, bytesPerRow)
    }

    private func content(_ frame: (pixels: [UInt8], bytesPerRow: Int)) -> HeroTrailerCrop.Content? {
        frame.pixels.withUnsafeBufferPointer {
            HeroTrailerCrop.content(luma: $0, width: width, height: height, bytesPerRow: frame.bytesPerRow)
        }
    }

    // MARK: - Detection

    /// The real case: a 2.39:1 film in a 1920x1080 file, 1920x804 of picture
    /// with 138 rows of black above and below (ffmpeg cropdetect on the
    /// library's trailers reports exactly this).
    func testFindsScopeLetterboxBars() throws {
        let found = try XCTUnwrap(content(frame(blackTop: 138, blackBottom: 138)))
        XCTAssertEqual(found.top, 138.0 / 1080, accuracy: 0.0001)
        XCTAssertEqual(found.bottom, 138.0 / 1080, accuracy: 0.0001)
        XCTAssertEqual(found.left, 0)
        XCTAssertEqual(found.right, 0)
    }

    func testReadsRowsThroughThePlanesPadding() throws {
        let found = try XCTUnwrap(content(frame(blackTop: 138, blackBottom: 138, padding: 64)))
        XCTAssertEqual(found.top, 138.0 / 1080, accuracy: 0.0001)
    }

    func testAFullFrameTrailerHasNoBars() {
        XCTAssertEqual(content(frame()), .full)
    }

    /// Bars come in equal pairs: a dark sky with nothing matching it at the
    /// bottom is picture, not letterbox.
    func testADarkTopWithoutAMatchingBottomIsNotABar() {
        XCTAssertEqual(content(frame(blackTop: 200)), .full)
    }

    /// Unequal bars (an encode a row or two off-centre) crop only the thinner.
    func testUnequalBarsCropTheThinnerOnBothEdges() throws {
        let found = try XCTUnwrap(content(frame(blackTop: 140, blackBottom: 130)))
        XCTAssertEqual(found.top, 130.0 / 1080, accuracy: 0.0001)
        XCTAssertEqual(found.bottom, 130.0 / 1080, accuracy: 0.0001)
    }

    func testFindsPillarboxBars() throws {
        let found = try XCTUnwrap(content(frame(blackLeft: 240, blackRight: 240)))
        XCTAssertEqual(found.left, 240.0 / 1920, accuracy: 0.0001)
        XCTAssertEqual(found.right, 240.0 / 1920, accuracy: 0.0001)
        XCTAssertEqual(found.top, 0)
    }

    func testIgnoresHairlineBars() {
        XCTAssertEqual(content(frame(blackTop: 4, blackBottom: 4)), .full)
    }

    /// A fade from black or a studio logo on black says nothing about bars.
    func testAMostlyBlackFrameCantTell() {
        XCTAssertNil(content(frame(blackTop: 400, blackBottom: 400)))
        XCTAssertNil(content(frame(bright: 16)))
    }

    /// A bar is only a bar where every frame has one: a dark first shot is
    /// corrected by a brighter one.
    func testFramesCombineToTheLargestPicture() {
        let dark = HeroTrailerCrop.Content(top: 0.2, bottom: 0.2, left: 0, right: 0)
        let scope = HeroTrailerCrop.Content(top: 0.128, bottom: 0.128, left: 0, right: 0)
        XCTAssertEqual(dark.union(scope), scope)
        XCTAssertEqual(scope.union(.full), .full)
    }

    // MARK: - Framing

    /// The detail hero on Apple TV: 55% of 1920pt wide, a 16:9 backdrop.
    private let hero = CGSize(width: 1056, height: 594)
    private let video = CGSize(width: 1920, height: 1080)

    /// The bug. Framing the whole letterboxed frame (what the hero did)
    /// leaves ~76pt of black above the picture; framing the picture puts
    /// its top edge on the hero's (the screen's) top edge and its right edge
    /// on the screen's right edge.
    func testALetterboxedTrailersPictureIsFlushTopAndRight() throws {
        let measured = try XCTUnwrap(content(frame(blackTop: 138, blackBottom: 138)))
        let placed = try XCTUnwrap(HeroTrailerCrop.videoFrame(box: hero, videoSize: video, content: measured))
        let pictureTop = placed.minY + measured.top * placed.height
        let pictureBottom = placed.maxY - measured.bottom * placed.height
        let pictureRight = placed.maxX - measured.right * placed.width
        XCTAssertEqual(pictureTop, 0, accuracy: 0.5, "no band above the picture")
        XCTAssertEqual(pictureBottom, hero.height, accuracy: 0.5, "no band below it")
        XCTAssertGreaterThanOrEqual(pictureRight, hero.width - 0.5, "no gap on the right")

        let uncropped = try XCTUnwrap(HeroTrailerCrop.videoFrame(box: hero, videoSize: video, content: .full))
        XCTAssertEqual(uncropped.minY + measured.top * uncropped.height, 75.9, accuracy: 0.5,
                       "the whole frame leaves the black band the owner saw")
    }

    /// No bars: exactly the old aspect-fill of the whole frame.
    func testWithoutBarsItIsPlainAspectFill() throws {
        XCTAssertEqual(try XCTUnwrap(HeroTrailerCrop.videoFrame(box: hero, videoSize: video, content: .full)),
                       CGRect(origin: .zero, size: hero))
        // A wider box (a YouTube banner hero) crops top and bottom, centred.
        let banner = CGSize(width: 1152, height: 300)
        let placed = try XCTUnwrap(HeroTrailerCrop.videoFrame(box: banner, videoSize: video, content: .full))
        XCTAssertEqual(placed.width, 1152, accuracy: 0.001)
        XCTAssertEqual(placed.midY, 150, accuracy: 0.001)
    }

    func testUnknownSizesFallBack() {
        XCTAssertNil(HeroTrailerCrop.videoFrame(box: hero, videoSize: .zero, content: .full))
        XCTAssertNil(HeroTrailerCrop.videoFrame(box: .zero, videoSize: video, content: .full))
    }
}
