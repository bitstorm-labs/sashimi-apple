import Foundation

/// Makes a downloaded HEVC MP4 renderable by AVFoundation (#817).
///
/// An Original-quality download is a stream-copy remux from Jellyfin's
/// progressive `stream.mp4`. Unlike its HLS path, that endpoint never passes
/// `-tag:v hvc1`, so ffmpeg writes its default `hev1` sample entry.
/// AVFoundation plays such a file's audio and renders no video at all: a
/// black screen (a 4K Dolby Vision WEBDL on the Mac, Oct 2026).
///
/// The two entries differ only in where the parameter sets may live. `hvc1`
/// requires them in the `hvcC` record, and a remux from MKV puts them there,
/// so relabelling the entry is enough: four bytes in the file header, no
/// rewrite of the media. An `hev1` whose `hvcC` carries no parameter sets is
/// left alone, since as `hvc1` it would have none at all.
enum MP4HEVCSampleEntry {
    enum Outcome: Equatable {
        case retagged
        case unchanged
    }

    /// Relabels every `hev1` video sample entry in the file as `hvc1`, in
    /// place. Cheap enough for the main actor: it reads box headers to find
    /// `moov`, then only `moov` itself. Throws only when the file cannot be
    /// opened or written; a file it does not understand is `.unchanged`.
    static func makePlayable(fileAt url: URL) throws -> Outcome {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        guard let moov = try moovBox(in: handle) else { return .unchanged }
        let offsets = hev1Offsets(in: moov.payload, baseOffset: moov.payloadOffset)
        guard !offsets.isEmpty else { return .unchanged }

        for offset in offsets {
            try handle.seek(toOffset: offset)
            try handle.write(contentsOf: Data("hvc1".utf8))
        }
        try handle.synchronize()
        return .retagged
    }

    // MARK: - Box walking

    /// `moov` is a few kilobytes even for a long fragmented file; anything far
    /// larger is not a box this needs to read.
    private static let maxMoovSize: UInt64 = 64 * 1024 * 1024

    private struct Header {
        let type: String
        let headerSize: UInt64
        let size: UInt64
    }

    private static func header(_ bytes: Data, available: UInt64) -> Header? {
        guard bytes.count >= 8 else { return nil }
        let size32 = bytes.prefix(4).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard let type = String(bytes: bytes.dropFirst(4).prefix(4), encoding: .isoLatin1) else { return nil }
        let header: Header
        switch size32 {
        case 0:
            header = Header(type: type, headerSize: 8, size: available)
        case 1:
            guard bytes.count >= 16 else { return nil }
            let size64 = bytes.dropFirst(8).prefix(8).reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            header = Header(type: type, headerSize: 16, size: size64)
        default:
            header = Header(type: type, headerSize: 8, size: size32)
        }
        guard header.size >= header.headerSize, header.size <= available else { return nil }
        return header
    }

    private static func moovBox(in handle: FileHandle) throws -> (payload: Data, payloadOffset: UInt64)? {
        let fileSize = try handle.seekToEnd()
        var offset: UInt64 = 0
        while offset + 8 <= fileSize {
            try handle.seek(toOffset: offset)
            let bytes = try handle.read(upToCount: 16) ?? Data()
            guard let box = header(bytes, available: fileSize - offset) else { return nil }
            if box.type == "moov" {
                let payloadSize = box.size - box.headerSize
                guard payloadSize <= maxMoovSize else { return nil }
                try handle.seek(toOffset: offset + box.headerSize)
                guard let payload = try handle.read(upToCount: Int(payloadSize)),
                      UInt64(payload.count) == payloadSize else { return nil }
                return (payload, offset + box.headerSize)
            }
            offset += box.size
        }
        return nil
    }

    private static let containers: Set<String> = ["moov", "trak", "mdia", "minf", "stbl"]

    /// File offsets of the fourcc of each `hev1` entry that can become `hvc1`.
    private static func hev1Offsets(in data: Data, baseOffset: UInt64) -> [UInt64] {
        var found: [UInt64] = []
        forEachBox(in: data, from: 0, to: data.count) { type, _, payloadStart, end in
            if containers.contains(type) {
                found += hev1Offsets(in: data.subdata(in: payloadStart..<end), baseOffset: baseOffset + UInt64(payloadStart))
            } else if type == "stsd" {
                // version/flags (4) + entry_count (4), then one box per entry.
                forEachBox(in: data, from: payloadStart + 8, to: end) { entry, entryStart, entryPayload, entryEnd in
                    // A visual sample entry has 78 bytes of fixed fields before
                    // its child boxes (ISO/IEC 14496-12 §12.1.3).
                    guard entry == "hev1",
                          hasParameterSets(in: data, from: entryPayload + 78, to: entryEnd) else { return }
                    found.append(baseOffset + UInt64(entryStart + 4))
                }
            }
        }
        return found
    }

    /// Whether the entry's `hvcC` lists at least one parameter-set array
    /// (`numOfArrays`, the 23rd byte of its payload).
    private static func hasParameterSets(in data: Data, from: Int, to end: Int) -> Bool {
        var result = false
        forEachBox(in: data, from: from, to: end) { type, _, payloadStart, boxEnd in
            if type == "hvcC", payloadStart + 22 < boxEnd, data[payloadStart + 22] > 0 {
                result = true
            }
        }
        return result
    }

    /// Calls `body(type, start, payloadStart, end)` for each well-formed box
    /// in `data[from..<to]`, stopping at the first malformed one. `data` must
    /// be zero-based.
    private static func forEachBox(in data: Data, from: Int, to end: Int, _ body: (String, Int, Int, Int) -> Void) {
        var offset = from
        while offset >= 0, offset + 8 <= end {
            let bytes = data.subdata(in: offset..<min(offset + 16, end))
            guard let box = header(bytes, available: UInt64(end - offset)), box.type != "\0\0\0\0" else { return }
            let boxEnd = offset + Int(box.size)
            body(box.type, offset, offset + Int(box.headerSize), boxEnd)
            offset = boxEnd
        }
    }
}
