import Foundation
import Testing
@testable import Persistence

@Suite("ZipContainer")
struct ZipContainerTests {
    // MARK: - Temp helpers

    private func makeDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zip-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, to dir: URL, path: String) throws {
        let url = dir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Collects every regular file under `dir` as relative-path → bytes.
    private func snapshot(_ dir: URL) throws -> [String: Data] {
        let fm = FileManager.default
        let base = dir.standardizedFileURL.path + "/"
        var out: [String: Data] = [:]
        let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey])!
        for case let url as URL in e {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            out[String(full.dropFirst(base.count))] = try Data(contentsOf: url)
        }
        return out
    }

    // MARK: - Round-trip

    @Test("round-trips a nested tree (text + binary + multi-MB) byte-identically")
    func roundTrip() throws {
        let src = try makeDir()
        try write(Data("hello manifest".utf8), to: src, path: "manifest.json")
        try write(Data([0x00, 0xFF, 0x10, 0x7F, 0x80, 0x01]), to: src, path: "thumbnails/a.jpg")
        try write(Data("voice bytes".utf8), to: src, path: "voice/clip.m4a")

        // A ~3 MiB file to exercise the multi-chunk streaming path (chunk is 1 MiB).
        var big = Data(count: 3 * (1 << 20) + 123)
        for i in stride(from: 0, to: big.count, by: 7) { big[i] = UInt8(i & 0xFF) }
        try write(big, to: src, path: "videos/clip.mov")

        let archive = try makeDir().appendingPathComponent("out.zip")
        try ZipContainer.zip(directory: src, to: archive)

        let dest = try makeDir()
        try ZipContainer.unzip(archive, to: dest)

        #expect(try snapshot(dest) == snapshot(src))
    }

    @Test("its own output has a valid EOCD / central directory")
    func ownOutputParses() throws {
        let src = try makeDir()
        try write(Data("a".utf8), to: src, path: "one.txt")
        try write(Data("bb".utf8), to: src, path: "sub/two.txt")
        let archive = try makeDir().appendingPathComponent("out.zip")
        try ZipContainer.zip(directory: src, to: archive)

        let bytes = try Data(contentsOf: archive)
        // EOCD is the last 22 bytes (no comment).
        let eocd = bytes.count - 22
        #expect(readLE32(bytes, eocd) == 0x0605_4b50)
        let totalEntries = readLE16(bytes, eocd + 10)
        let cdSize = readLE32(bytes, eocd + 12)
        let cdOffset = readLE32(bytes, eocd + 16)
        #expect(totalEntries == 2)
        // Central directory sits where the EOCD says, and its first record has the
        // central-header signature.
        #expect(readLE32(bytes, Int(cdOffset)) == 0x0201_4b50)
        #expect(Int(cdOffset) + Int(cdSize) == eocd)
    }

    @Test("zips and unzips an empty directory")
    func emptyDir() throws {
        let src = try makeDir()
        let archive = try makeDir().appendingPathComponent("empty.zip")
        try ZipContainer.zip(directory: src, to: archive)

        let bytes = try Data(contentsOf: archive)
        #expect(bytes.count == 22)  // just the EOCD
        #expect(readLE16(bytes, 10) == 0)  // zero entries

        let dest = try makeDir()
        try ZipContainer.unzip(archive, to: dest)
        #expect(try snapshot(dest).isEmpty)
    }

    // MARK: - Security / robustness (hand-crafted hostile archives)

    @Test("rejects a zip-slip entry that escapes the destination")
    func rejectsZipSlip() throws {
        let payload = Data("pwned".utf8)
        let zip = buildZip([ForgedEntry(name: "../escape.txt", data: payload)])
        let archive = try makeDir().appendingPathComponent("slip.zip")
        try zip.write(to: archive)
        let dest = try makeDir()

        #expect(throws: ZipContainer.ZipError.self) {
            try ZipContainer.unzip(archive, to: dest)
        }
    }

    @Test("rejects an absolute-path entry")
    func rejectsAbsolutePath() throws {
        let zip = buildZip([ForgedEntry(name: "/etc/evil", data: Data("x".utf8))])
        let archive = try makeDir().appendingPathComponent("abs.zip")
        try zip.write(to: archive)
        #expect(throws: ZipContainer.ZipError.self) {
            try ZipContainer.unzip(archive, to: try makeDir())
        }
    }

    @Test("rejects a non-stored (compressed) entry")
    func rejectsCompressedMethod() throws {
        let zip = buildZip([ForgedEntry(name: "a.txt", data: Data("x".utf8), method: 8)])
        let archive = try makeDir().appendingPathComponent("deflate.zip")
        try zip.write(to: archive)
        #expect {
            try ZipContainer.unzip(archive, to: try makeDir())
        } throws: { error in
            if case ZipContainer.ZipError.unsupportedEntry = error { return true }
            return false
        }
    }

    @Test("rejects an encrypted entry")
    func rejectsEncrypted() throws {
        let zip = buildZip([ForgedEntry(name: "a.txt", data: Data("x".utf8), flags: 0x0001)])
        let archive = try makeDir().appendingPathComponent("enc.zip")
        try zip.write(to: archive)
        #expect {
            try ZipContainer.unzip(archive, to: try makeDir())
        } throws: { error in
            if case ZipContainer.ZipError.unsupportedEntry = error { return true }
            return false
        }
    }

    @Test("detects a CRC mismatch")
    func detectsCrcMismatch() throws {
        let zip = buildZip([ForgedEntry(name: "a.txt", data: Data("hello".utf8), crcOverride: 0xDEAD_BEEF)])
        let archive = try makeDir().appendingPathComponent("badcrc.zip")
        try zip.write(to: archive)
        #expect {
            try ZipContainer.unzip(archive, to: try makeDir())
        } throws: { error in
            if case ZipContainer.ZipError.crcMismatch = error { return true }
            return false
        }
    }

    @Test("throws on a file that is not a zip")
    func rejectsGarbage() throws {
        let archive = try makeDir().appendingPathComponent("garbage.zip")
        try Data("this is definitely not a zip file".utf8).write(to: archive)
        #expect(throws: ZipContainer.ZipError.self) {
            try ZipContainer.unzip(archive, to: try makeDir())
        }
    }

    @Test("a mid-archive failure removes every already-extracted file and created dir")
    func cleansUpPartialExtraction() throws {
        // First entry is valid and nested (so extraction creates a subdirectory); the
        // second uses an unsupported method so the loop throws *after* the first is on
        // disk. Cleanup must wipe the first file and the directory it created.
        let zip = buildZip([
            ForgedEntry(name: "sub/good.txt", data: Data("good".utf8)),
            ForgedEntry(name: "bad.txt", data: Data("bad".utf8), method: 8)
        ])
        let archive = try makeDir().appendingPathComponent("partial.zip")
        try zip.write(to: archive)
        let dest = try makeDir()

        #expect(throws: ZipContainer.ZipError.self) {
            try ZipContainer.unzip(archive, to: dest)
        }
        // No leftover files — and the created subdirectory is gone too.
        #expect(try snapshot(dest).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    @Test("rejects an empty / dot-only entry name")
    func rejectsDotOnlyName() throws {
        let zip = buildZip([ForgedEntry(name: ".", data: Data("x".utf8))])
        let archive = try makeDir().appendingPathComponent("dotname.zip")
        try zip.write(to: archive)
        let dest = try makeDir()
        #expect {
            try ZipContainer.unzip(archive, to: dest)
        } throws: { error in
            if case ZipContainer.ZipError.malformed = error { return true }
            return false
        }
        // Nothing was written for the bogus entry.
        #expect(try snapshot(dest).isEmpty)
    }

    @Test("caps an EOCD that claims an absurd central-directory size")
    func rejectsOversizedCentralDirectory() throws {
        var zip = buildZip([ForgedEntry(name: "a.txt", data: Data("x".utf8))])
        // Patch the EOCD's central-directory size field (4 bytes at len-10) to 100 MiB —
        // past the reader's cap and the tiny archive — so a naive reader would allocate it.
        let off = zip.count - 10
        let huge: UInt32 = 100 * (1 << 20)
        zip[zip.startIndex + off]     = UInt8(huge & 0xFF)
        zip[zip.startIndex + off + 1] = UInt8((huge >> 8) & 0xFF)
        zip[zip.startIndex + off + 2] = UInt8((huge >> 16) & 0xFF)
        zip[zip.startIndex + off + 3] = UInt8((huge >> 24) & 0xFF)
        let archive = try makeDir().appendingPathComponent("bigcd.zip")
        try zip.write(to: archive)
        #expect {
            try ZipContainer.unzip(archive, to: try makeDir())
        } throws: { error in
            if case ZipContainer.ZipError.malformed = error { return true }
            return false
        }
    }

    @Test("refuses a non-empty destination directory")
    func rejectsNonEmptyDestination() throws {
        let src = try makeDir()
        try write(Data("m".utf8), to: src, path: "manifest.json")
        let archive = try makeDir().appendingPathComponent("ok.zip")
        try ZipContainer.zip(directory: src, to: archive)

        let dest = try makeDir()
        try write(Data("pre".utf8), to: dest, path: "pre-existing.txt")
        #expect {
            try ZipContainer.unzip(archive, to: dest)
        } throws: { error in
            if case ZipContainer.ZipError.malformed = error { return true }
            return false
        }
    }

    // MARK: - Hand-rolled forged-zip builder (mirrors the on-disk format)

    private struct ForgedEntry {
        var name: String
        var data: Data
        var method: UInt16 = 0
        var flags: UInt16 = 0
        var crcOverride: UInt32?
    }

    /// Builds a minimal stored-zip byte stream with full control over each entry's name,
    /// method, flags, and CRC — used to synthesize hostile archives the writer would
    /// never produce.
    private func buildZip(_ entries: [ForgedEntry]) -> Data {
        var out = Data()
        var central = Data()
        var offset = 0

        for e in entries {
            let nameBytes = Array(e.name.utf8)
            let crc = e.crcOverride ?? crc32(e.data)
            let size = UInt32(e.data.count)
            let localOffset = UInt32(offset)

            var lh = Data()
            appendLE(&lh, UInt32(0x0403_4b50))
            appendLE(&lh, UInt16(20)); appendLE(&lh, e.flags); appendLE(&lh, e.method)
            appendLE(&lh, UInt16(0)); appendLE(&lh, UInt16(0))       // time/date
            appendLE(&lh, crc); appendLE(&lh, size); appendLE(&lh, size)
            appendLE(&lh, UInt16(nameBytes.count)); appendLE(&lh, UInt16(0))
            lh.append(contentsOf: nameBytes)
            out.append(lh)
            out.append(e.data)
            offset += lh.count + e.data.count

            appendLE(&central, UInt32(0x0201_4b50))
            appendLE(&central, UInt16(20)); appendLE(&central, UInt16(20))
            appendLE(&central, e.flags); appendLE(&central, e.method)
            appendLE(&central, UInt16(0)); appendLE(&central, UInt16(0))
            appendLE(&central, crc); appendLE(&central, size); appendLE(&central, size)
            appendLE(&central, UInt16(nameBytes.count))
            appendLE(&central, UInt16(0)); appendLE(&central, UInt16(0))   // extra, comment
            appendLE(&central, UInt16(0)); appendLE(&central, UInt16(0))   // disk, internal attrs
            appendLE(&central, UInt32(0))                                   // external attrs
            appendLE(&central, localOffset)
            central.append(contentsOf: nameBytes)
        }

        let cdStart = UInt32(offset)
        let cdSize = UInt32(central.count)
        out.append(central)

        appendLE(&out, UInt32(0x0605_4b50))
        appendLE(&out, UInt16(0)); appendLE(&out, UInt16(0))
        appendLE(&out, UInt16(entries.count)); appendLE(&out, UInt16(entries.count))
        appendLE(&out, cdSize); appendLE(&out, cdStart); appendLE(&out, UInt16(0))
        return out
    }

    // MARK: - Little-endian + CRC helpers (test-local)

    private func appendLE(_ d: inout Data, _ v: UInt16) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
    }

    private func appendLE(_ d: inout Data, _ v: UInt32) {
        d.append(UInt8(v & 0xFF)); d.append(UInt8((v >> 8) & 0xFF))
        d.append(UInt8((v >> 16) & 0xFF)); d.append(UInt8((v >> 24) & 0xFF))
    }

    private func readLE16(_ d: Data, _ o: Int) -> UInt16 {
        let i = d.startIndex + o
        return UInt16(d[i]) | (UInt16(d[i + 1]) << 8)
    }

    private func readLE32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        return UInt32(d[i]) | (UInt32(d[i + 1]) << 8) | (UInt32(d[i + 2]) << 16) | (UInt32(d[i + 3]) << 24)
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (0xEDB8_8320 ^ (crc >> 1)) : (crc >> 1)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}
