import AVFoundation
import CoreGraphics
import CoreVideo
import QuartzCore

/// Black bars baked into a hero trailer's picture, and how to frame the
/// picture without them.
///
/// About half of the library's trailers are scope films letterboxed inside a
/// 16:9 file: a 1920x1080 frame whose picture is 1920x804, with 138 rows of
/// black above and below it. Filling the hero with the whole frame put that
/// black band across the top of the hero, so the picture looked pushed down
/// from the screen's top edge while the trailer played. The picture has to
/// fill the hero instead, flush top and right like the image under it.
///
/// Pure, so the detection and the framing are testable without a player.
enum HeroTrailerCrop {
    /// A row or column is a bar while its mean luma is at most this. Video
    /// range black is 16; compression noise in a bar stays well under 32,
    /// while real picture rarely averages that dark across a whole row.
    static let blackLimit: UInt8 = 32
    /// Bars thinner than this fraction of the frame are left alone (noise,
    /// or a soft edge in the encode).
    static let minimumBar: CGFloat = 0.01
    /// A frame whose picture looks smaller than this, on either axis, is a
    /// dark scene, a fade or a logo on black, not a letterbox. Ignored.
    static let minimumPicture: CGFloat = 0.5
    /// Sample every Nth pixel along a row or column.
    static let stride = 8

    /// The picture's rectangle inside the frame, in unit coordinates (0...1,
    /// origin top-left). The full frame when there are no bars.
    struct Content: Equatable {
        var top: CGFloat = 0
        var bottom: CGFloat = 0
        var left: CGFloat = 0
        var right: CGFloat = 0

        static let full = Content()

        var rect: CGRect {
            CGRect(x: left, y: top, width: 1 - left - right, height: 1 - top - bottom)
        }

        /// Both frames' picture: a bar is only a bar where every frame has one.
        func union(_ other: Content) -> Content {
            Content(
                top: min(top, other.top),
                bottom: min(bottom, other.bottom),
                left: min(left, other.left),
                right: min(right, other.right)
            )
        }
    }

    /// The bars in one frame's luma plane, or nil when the frame can't tell
    /// (too dark to separate picture from bar).
    ///
    /// Letterbox and pillarbox bars come in equal pairs, so each axis uses the
    /// thinner of its two: a dark sky at the top of a full-frame shot has no
    /// matching band at the bottom and isn't mistaken for a bar.
    static func content(luma: UnsafeBufferPointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) -> Content? {
        guard width > 0, height > 0, bytesPerRow >= width, luma.count >= bytesPerRow * height else { return nil }
        func isBlackRow(_ y: Int) -> Bool {
            var sum = 0, count = 0
            for x in Swift.stride(from: 0, to: width, by: stride) {
                sum += Int(luma[y * bytesPerRow + x]); count += 1
            }
            return sum <= Int(blackLimit) * count
        }
        func isBlackColumn(_ x: Int) -> Bool {
            var sum = 0, count = 0
            for y in Swift.stride(from: 0, to: height, by: stride) {
                sum += Int(luma[y * bytesPerRow + x]); count += 1
            }
            return sum <= Int(blackLimit) * count
        }
        let top = (0..<height).first { !isBlackRow($0) } ?? height
        guard top < height else { return nil }
        let bottom = height - 1 - ((0..<height).reversed().first { !isBlackRow($0) } ?? 0)
        let left = (0..<width).first { !isBlackColumn($0) } ?? width
        let right = width - 1 - ((0..<width).reversed().first { !isBlackColumn($0) } ?? 0)

        let vertical = bar(min(top, bottom), of: height)
        let horizontal = bar(min(left, right), of: width)
        let pictureHeight = CGFloat(height - top - bottom) / CGFloat(height)
        let pictureWidth = CGFloat(width - left - right) / CGFloat(width)
        guard pictureHeight >= minimumPicture, pictureWidth >= minimumPicture else { return nil }
        return Content(top: vertical, bottom: vertical, left: horizontal, right: horizontal)
    }

    private static func bar(_ pixels: Int, of length: Int) -> CGFloat {
        let fraction = CGFloat(pixels) / CGFloat(length)
        return fraction < minimumBar ? 0 : fraction
    }

    /// The bars in a decoded frame (`kCVPixelFormatType_420YpCbCr8BiPlanar*`:
    /// plane 0 is luma).
    static func content(of pixelBuffer: CVPixelBuffer) -> Content? {
        guard CVPixelBufferIsPlanar(pixelBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let luma = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self), count: bytesPerRow * height)
        return content(luma: luma, width: width, height: height, bytesPerRow: bytesPerRow)
    }

    /// Where the whole video frame goes so its picture (`content`) fills
    /// `box`, centred, cropping whichever axis overflows: the hero's
    /// `resizeAspectFill`, applied to the picture instead of the frame. With
    /// no bars it is exactly `resizeAspectFill`. Nil until the video's size
    /// is known.
    static func videoFrame(box: CGSize, videoSize: CGSize, content: Content) -> CGRect? {
        let picture = content.rect
        guard box.width > 0, box.height > 0, videoSize.width > 0, videoSize.height > 0,
              picture.width > 0, picture.height > 0 else { return nil }
        let scale = max(
            box.width / (picture.width * videoSize.width),
            box.height / (picture.height * videoSize.height)
        )
        let size = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        let pictureCentre = CGPoint(x: picture.midX * size.width, y: picture.midY * size.height)
        return CGRect(
            x: box.width / 2 - pictureCentre.x,
            y: box.height / 2 - pictureCentre.y,
            width: size.width,
            height: size.height
        )
    }
}

extension HeroTrailerCrop {
    /// How long into the clip frames are read for bars.
    static let samplingWindow: Double = 5
    /// How long the reveal waits for a frame that shows the bars; past it the
    /// trailer shows uncropped (and is cropped once a frame can tell).
    static let revealWait: Double = 1
}

/// Reads a playing trailer's decoded frames for letterbox bars.
@MainActor
final class HeroTrailerBarMeter {
    private let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    ])
    /// The bars measured so far; nil until a frame bright enough to tell.
    private(set) var content: HeroTrailerCrop.Content?
    /// The frame size; zero until known.
    private(set) var videoSize = CGSize.zero

    init(item: AVPlayerItem) {
        item.add(output)
    }

    /// Reads the newest decoded frame. Every bright frame can only shrink the
    /// bars (a bar is only a bar where every frame has one), so a dark first
    /// shot that looked barred is corrected by the next.
    func sample(_ item: AVPlayerItem) {
        if videoSize == .zero, item.presentationSize != .zero { videoSize = item.presentationSize }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        if videoSize == .zero {
            videoSize = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        }
        guard let found = HeroTrailerCrop.content(of: buffer) else { return }
        content = content.map { $0.union(found) } ?? found
    }
}
