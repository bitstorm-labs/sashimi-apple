import XCTest
@testable import Sashimi

/// #817: an Original-quality download of an HEVC MKV is a stream-copy remux
/// from Jellyfin's progressive `stream.mp4`, which leaves ffmpeg's default
/// `hev1` sample entry. AVFoundation plays the audio of such a file and
/// renders no video at all — the black screen. Relabelling the entry `hvc1`
/// (its parameter sets are already in `hvcC`) makes the same bytes play.
final class MP4HEVCSampleEntryTests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MP4HEVCSampleEntryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Box builders

    private func box(_ type: String, _ payload: Data) -> Data {
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: UInt32(8 + payload.count).bigEndian, Array.init))
        data.append(contentsOf: Array(type.utf8))
        data.append(payload)
        return data
    }

    /// An `hvcC` with `arrays` parameter-set arrays (VPS/SPS/PPS when > 0).
    private func hvcC(arrays: UInt8) -> Data {
        var payload = Data(repeating: 0, count: 22)
        payload.append(arrays)
        for index in 0..<arrays {
            payload.append(0x20 + index)          // NAL unit type
            payload.append(contentsOf: [0, 1])    // one NAL unit
            payload.append(contentsOf: [0, 2, 0xAB, 0xCD])
        }
        return box("hvcC", payload)
    }

    /// A visual sample entry: 78 bytes of fixed fields, then child boxes.
    private func sampleEntry(_ type: String, children: Data) -> Data {
        box(type, Data(repeating: 0, count: 78) + children)
    }

    private func stsd(_ entries: [Data]) -> Data {
        var payload = Data([0, 0, 0, 0])
        payload.append(contentsOf: withUnsafeBytes(of: UInt32(entries.count).bigEndian, Array.init))
        entries.forEach { payload.append($0) }
        return box("stsd", payload)
    }

    private func trak(_ stsd: Data) -> Data {
        box("trak", box("tkhd", Data(repeating: 0, count: 84))
            + box("mdia", box("mdhd", Data(repeating: 0, count: 24))
                + box("minf", box("stbl", stsd))))
    }

    /// ftyp, moov (one trak per stsd), then a media box.
    private func mp4(_ tracks: [Data], moovLast: Bool = false) -> Data {
        let ftyp = box("ftyp", Data("isom".utf8) + Data(repeating: 0, count: 4))
        let moov = box("moov", box("mvhd", Data(repeating: 0, count: 100)) + tracks.reduce(Data(), +))
        let mdat = box("mdat", Data(repeating: 0x5A, count: 64))
        return moovLast ? ftyp + mdat + moov : ftyp + moov + mdat
    }

    private func write(_ data: Data) throws -> URL {
        let url = directory.appendingPathComponent("\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    private func sampleEntryTypes(in url: URL) throws -> [String] {
        let data = try Data(contentsOf: url)
        return ["hev1", "hvc1", "avc1", "ec-3"].filter { data.range(of: Data($0.utf8)) != nil }
    }

    // MARK: - Tests

    func testRetagsHev1WithParameterSetsAsHvc1() throws {
        let original = mp4([trak(stsd([sampleEntry("hev1", children: hvcC(arrays: 3))]))])
        let url = try write(original)

        XCTAssertEqual(try MP4HEVCSampleEntry.makePlayable(fileAt: url), .retagged)

        let patched = try Data(contentsOf: url)
        XCTAssertEqual(try sampleEntryTypes(in: url), ["hvc1"])
        XCTAssertEqual(patched.count, original.count, "a relabel, never a rewrite")
        let differing = zip(original, patched).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset)
        XCTAssertEqual(differing.count, 2, "only 'ev' of the hev1 fourcc becomes 'vc'")
    }

    func testRetagsEveryVideoTrackAndLeavesAudioAlone() throws {
        let url = try write(mp4([
            trak(stsd([sampleEntry("hev1", children: hvcC(arrays: 3))])),
            trak(stsd([box("ec-3", Data(repeating: 0, count: 40))])),
            trak(stsd([sampleEntry("hev1", children: hvcC(arrays: 2))]))
        ]))

        XCTAssertEqual(try MP4HEVCSampleEntry.makePlayable(fileAt: url), .retagged)
        XCTAssertEqual(try sampleEntryTypes(in: url), ["hvc1", "ec-3"])
    }

    func testFindsMoovAfterMediaData() throws {
        let url = try write(mp4([trak(stsd([sampleEntry("hev1", children: hvcC(arrays: 3))]))], moovLast: true))

        XCTAssertEqual(try MP4HEVCSampleEntry.makePlayable(fileAt: url), .retagged)
        XCTAssertEqual(try sampleEntryTypes(in: url), ["hvc1"])
    }

    /// hev1 may carry its parameter sets only in-band; as hvc1 that stream
    /// would have none at all, so it is left as the server wrote it.
    func testLeavesHev1WithoutParameterSetsUntouched() throws {
        let original = mp4([trak(stsd([sampleEntry("hev1", children: hvcC(arrays: 0))]))])
        let url = try write(original)

        XCTAssertEqual(try MP4HEVCSampleEntry.makePlayable(fileAt: url), .unchanged)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testAlreadyPlayableFilesAreUnchanged() throws {
        for type in ["hvc1", "avc1"] {
            let original = mp4([trak(stsd([sampleEntry(type, children: hvcC(arrays: 3))]))])
            let url = try write(original)

            XCTAssertEqual(try MP4HEVCSampleEntry.makePlayable(fileAt: url), .unchanged, type)
            XCTAssertEqual(try Data(contentsOf: url), original, type)
        }
    }

    func testRunningTwiceIsHarmless() throws {
        let url = try write(mp4([trak(stsd([sampleEntry("hev1", children: hvcC(arrays: 3))]))]))

        XCTAssertEqual(try MP4HEVCSampleEntry.makePlayable(fileAt: url), .retagged)
        XCTAssertEqual(try MP4HEVCSampleEntry.makePlayable(fileAt: url), .unchanged)
    }

    func testMalformedFilesAreLeftAloneWithoutCrashing() throws {
        let valid = mp4([trak(stsd([sampleEntry("hev1", children: hvcC(arrays: 3))]))])
        let inputs: [Data] = [
            Data(),
            Data([0, 0, 0]),
            valid.prefix(60),                             // moov cut short
            box("moov", Data([0, 0, 0, 200]) + Data("trak".utf8)),  // child overruns parent
            Data([0, 0, 0, 1]) + Data("moov".utf8)        // 64-bit size missing
        ]
        for (index, input) in inputs.enumerated() {
            let url = try write(input)
            XCTAssertEqual(try MP4HEVCSampleEntry.makePlayable(fileAt: url), .unchanged, "input \(index)")
            XCTAssertEqual(try Data(contentsOf: url), input, "input \(index)")
        }
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try MP4HEVCSampleEntry.makePlayable(fileAt: directory.appendingPathComponent("nope.mp4")))
    }
}
