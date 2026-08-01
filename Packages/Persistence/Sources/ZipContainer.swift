import Foundation

/// A hand-rolled, Foundation-only ZIP reader/writer for DiveFree's backup container.
///
/// ## Why hand-rolled?
///
/// A DiveFree backup is a `.zip` holding a JSON manifest plus discrete media files
/// (voice notes, photo/video originals, thumbnails). We deliberately avoid a
/// third-party zip dependency and Apple's `Compression`/`AppleArchive` frameworks:
/// the format we need is tiny, the security surface (we parse *user-selected* files
/// on restore) demands code we fully control and can audit, and staying
/// Foundation-only keeps the Persistence package dependency-free.
///
/// ## Why *stored* only (no compression)?
///
/// Every payload we bundle — jpeg/heic photos, m4a audio, mp4/mov video — is already
/// entropy-compressed. Re-running DEFLATE over it would burn CPU (and code) for a
/// fraction of a percent. So we use compression **method 0 (stored)** exclusively:
/// entry bytes are copied verbatim. The archive is still a perfectly standard `.zip`
/// that Finder and `unzip` open, it just never deflates.
///
/// ## Format written (PKWARE APPNOTE, the ubiquitous subset)
///
/// For each file, in this order:
///   1. a **local file header** (`0x04034b50`) + the raw file bytes,
/// then after all files:
///   2. a **central directory** — one record (`0x02014b50`) per file, and
///   3. an **end-of-central-directory** record (EOCD, `0x06054b50`).
///
/// Because every file already lives on disk, its size and CRC-32 are known *before*
/// we write its header, so we write correct sizes directly and **never** use data
/// descriptors (general-purpose bit 3). CRC-32 (polynomial `0xEDB88320`) is required
/// by the spec in both the local and central headers even for stored entries, so we
/// stream it over each file's bytes.
///
/// ## Streaming (never load a whole video into memory)
///
/// Both directions operate on files via `FileHandle`, copying in ~1 MiB chunks. A
/// multi-gigabyte video is read/written incrementally; the peak footprint is one
/// chunk plus the (small) central directory, regardless of entry size.
///
/// ## zip64 is unsupported — and guarded, not silently corrupted
///
/// The classic zip32 headers store sizes and offsets as 32-bit fields. We do **not**
/// implement zip64, so a single entry ≥ 4 GiB, or a whole archive whose bytes would
/// push a header offset past `UInt32.max`, cannot be represented. Rather than
/// overflow and emit a corrupt archive, we throw ``ZipError/entryTooLarge(_:)``.
///
/// ## Security (the reader is strict by construction)
///
/// `unzip(_:to:)` parses attacker-controllable input, so it refuses anything it does
/// not fully understand. It also requires a **fresh, empty destination directory** and
/// removes its partial output on *any* failure, so a hostile archive can neither
/// traverse a pre-existing symlink nor plant a chosen subset of files before aborting:
///   - **Zip-slip:** an entry name that is absolute, contains a `..` component, or a
///     backslash, is empty / dot-only, or whose resolved path escapes the destination
///     directory, is rejected (``ZipError/malformed(_:)``).
///   - **Unsupported entries:** any compression method other than 0, or the
///     encryption bit set, is rejected (``ZipError/unsupportedEntry(_:)``).
///   - **Integrity:** every extracted entry's CRC-32 is recomputed and compared to
///     the stored value; a mismatch throws ``ZipError/crcMismatch(_:)``.
///   - **Size caps:** per-entry and whole-archive size caps (the zip32 ceiling) are
///     enforced up front (``ZipError/entryTooLarge(_:)``).
/// Malformed bytes always surface as a typed ``ZipError`` — the reader never traps.
public enum ZipContainer {

    // MARK: - Errors

    /// A typed failure from reading or writing a zip. Every code path that could
    /// otherwise crash on hostile/truncated input throws one of these instead.
    public enum ZipError: Error, Equatable {
        /// The bytes are not a well-formed zip (bad signature, truncated header,
        /// out-of-range offset, …). The string is a short diagnostic.
        case malformed(String)
        /// A structurally valid entry we refuse to process: a non-stored compression
        /// method, or an encrypted entry.
        case unsupportedEntry(String)
        /// An extracted entry's recomputed CRC-32 did not match the stored value.
        case crcMismatch(String)
        /// An entry or the whole archive exceeds the zip32 size ceiling (zip64 is not
        /// supported).
        case entryTooLarge(String)
        /// More entries than the zip32 EOCD's 16-bit count field can represent (> 65535).
        case tooManyEntries(String)
    }

    // MARK: - Tunables

    /// Copy granularity for the streaming read/write loops (1 MiB).
    private static let chunkSize = 1 << 20

    /// Largest entry we will write or extract. The zip32 size/offset fields are 32-bit,
    /// so anything at or beyond 4 GiB cannot be represented without zip64.
    private static let maxEntrySize: UInt64 = 0xFFFF_FFFE

    /// The whole archive must stay within the zip32 offset space, because the central
    /// directory records and the EOCD store byte offsets as 32-bit values.
    private static let maxTotalSize: UInt64 = 0xFFFF_FFFE

    /// A sane ceiling on the central directory we're willing to read into memory. A
    /// legitimate central directory is tiny relative to a media backup (~46 bytes + a
    /// short name per entry); this caps a crafted EOCD from making us allocate up to the
    /// whole file. 64 MiB allows well over half a million entries.
    private static let maxCentralDirectorySize: UInt64 = 64 << 20

    // Signatures (little-endian on disk).
    private static let localHeaderSignature: UInt32 = 0x0403_4b50
    private static let centralHeaderSignature: UInt32 = 0x0201_4b50
    private static let eocdSignature: UInt32 = 0x0605_4b50

    // MARK: - Writing

    /// Zips every regular file under `directory` (recursively) into a new `.zip` at
    /// `destination`, using stored (uncompressed) entries.
    ///
    /// Entry names are POSIX relative paths with `/` separators (e.g. `voice/AbC.m4a`,
    /// `manifest.json`). Files are streamed, so a large video never fully loads into
    /// memory. Entry order is sorted for deterministic output.
    ///
    /// - Throws: ``ZipError/entryTooLarge(_:)`` if a file ≥ 4 GiB or the archive would
    ///   exceed the zip32 offset ceiling; rethrows filesystem errors.
    public static func zip(directory: URL, to destination: URL) throws {
        let fm = FileManager.default
        let files = try regularFiles(under: directory)

        // Create/replace the destination and open it for streaming writes.
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        fm.createFile(atPath: destination.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: destination) else {
            throw ZipError.malformed("cannot open destination for writing")
        }
        defer { try? out.close() }

        // Accumulates the central-directory record for every file as we go; written in
        // one block after all local entries.
        var centralRecords: [Data] = []
        var offset: UInt64 = 0  // running byte offset = start of the next local header

        for relativePath in files {
            let fileURL = directory.appendingPathComponent(relativePath)
            let size = try fileSize(of: fileURL)
            guard size <= maxEntrySize else {
                throw ZipError.entryTooLarge("\(relativePath) is \(size) bytes; zip64 (≥ 4 GiB) is unsupported")
            }

            let nameBytes = Array(relativePath.utf8)
            let crc = try crc32(ofFileAt: fileURL)
            let (dosTime, dosDate) = dosDateTime(from: modificationDate(of: fileURL))

            // Guard the whole-archive ceiling: this entry's header + data must not push
            // the offset (which later records and the EOCD encode as UInt32) past 4 GiB.
            let localHeaderSize = UInt64(30 + nameBytes.count)
            guard offset + localHeaderSize + size <= maxTotalSize else {
                throw ZipError.entryTooLarge("archive would exceed the zip32 4 GiB offset limit at \(relativePath)")
            }

            // --- Local file header ---
            var header = Data()
            header.appendLE(localHeaderSignature)
            header.appendLE(UInt16(20))            // version needed to extract (2.0)
            header.appendLE(UInt16(0x0800))        // flags: bit 11 = UTF-8 names; no encryption, no data descriptor
            header.appendLE(UInt16(0))             // compression method: 0 = stored
            header.appendLE(dosTime)
            header.appendLE(dosDate)
            header.appendLE(crc)
            header.appendLE(UInt32(size))          // compressed size == uncompressed size (stored)
            header.appendLE(UInt32(size))
            header.appendLE(UInt16(nameBytes.count))
            header.appendLE(UInt16(0))             // extra field length
            header.append(contentsOf: nameBytes)
            try out.write(contentsOf: header)

            // --- Entry data (streamed) ---
            try streamFile(at: fileURL, into: out)

            // --- Central directory record (buffered for later) ---
            var central = Data()
            central.appendLE(centralHeaderSignature)
            central.appendLE(UInt16(20))           // version made by (2.0, MS-DOS host)
            central.appendLE(UInt16(20))           // version needed to extract
            central.appendLE(UInt16(0x0800))       // flags
            central.appendLE(UInt16(0))            // compression method: stored
            central.appendLE(dosTime)
            central.appendLE(dosDate)
            central.appendLE(crc)
            central.appendLE(UInt32(size))
            central.appendLE(UInt32(size))
            central.appendLE(UInt16(nameBytes.count))
            central.appendLE(UInt16(0))            // extra field length
            central.appendLE(UInt16(0))            // file comment length
            central.appendLE(UInt16(0))            // disk number start
            central.appendLE(UInt16(0))            // internal file attributes
            central.appendLE(UInt32(0))            // external file attributes
            central.appendLE(UInt32(offset))       // relative offset of local header
            central.append(contentsOf: nameBytes)
            centralRecords.append(central)

            offset += localHeaderSize + size
        }

        // --- Central directory + EOCD ---
        // The EOCD encodes the entry count as UInt16 and the central-directory size as
        // UInt32; guard both so an outsized backup throws a typed error instead of
        // trapping on the narrowing conversion below.
        guard centralRecords.count <= 0xFFFF else {
            throw ZipError.tooManyEntries("\(centralRecords.count) entries; zip32 caps at 65535")
        }
        let centralStart = offset
        var directoryBlock = Data()
        for record in centralRecords {
            directoryBlock.append(record)
        }
        guard UInt64(directoryBlock.count) <= maxTotalSize else {
            throw ZipError.entryTooLarge("central directory is \(directoryBlock.count) bytes; exceeds the zip32 4 GiB limit")
        }
        try out.write(contentsOf: directoryBlock)

        var eocd = Data()
        eocd.appendLE(eocdSignature)
        eocd.appendLE(UInt16(0))                          // number of this disk
        eocd.appendLE(UInt16(0))                          // disk with the central directory
        eocd.appendLE(UInt16(centralRecords.count))       // central dir records on this disk
        eocd.appendLE(UInt16(centralRecords.count))       // total central dir records
        eocd.appendLE(UInt32(directoryBlock.count))       // size of central directory
        eocd.appendLE(UInt32(centralStart))               // offset of central directory
        eocd.appendLE(UInt16(0))                          // comment length
        try out.write(contentsOf: eocd)
    }

    // MARK: - Reading

    /// Extracts every entry of `archive` under `directory`, streaming each entry's
    /// bytes and validating its CRC-32. Rejects unsupported/encrypted entries and
    /// zip-slip paths (see the type doc). Parent directories are created as needed.
    ///
    /// - Important: `directory` **must be a freshly-created, empty directory** (this is
    ///   verified on entry). Containment against zip-slip is enforced lexically, which is
    ///   sound precisely because a freshly-created empty tree has no pre-existing symlink
    ///   component for a crafted name to traverse. On *any* failure the partial output is
    ///   removed, so a hostile archive cannot drop chosen files and then abort mid-extract.
    ///
    /// - Throws: ``ZipError`` on any malformed/unsupported/oversized input or a CRC
    ///   mismatch; rethrows filesystem errors. Never traps on hostile input.
    public static func unzip(_ archive: URL, to directory: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        // The lexical containment check below is only sound when the destination has no
        // pre-existing symlink components, so require a fresh, empty directory.
        let existing = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        guard existing.isEmpty else {
            throw ZipError.malformed("destination directory is not empty")
        }

        guard let handle = try? FileHandle(forReadingFrom: archive) else {
            throw ZipError.malformed("cannot open archive for reading")
        }
        defer { try? handle.close() }

        // Track what we create so any mid-archive failure leaves nothing behind. Removing
        // the created files/dirs (not the destination root, which the caller owns) means a
        // hostile archive can't plant files 0..<N and then throw on entry N.
        var createdFiles: [URL] = []
        var createdDirs: Set<String> = []
        func makeDirectory(_ url: URL) throws {
            if fm.fileExists(atPath: url.path) { return }
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
            createdDirs.insert(url.standardizedFileURL.path)
        }
        func cleanUp() {
            for file in createdFiles { try? fm.removeItem(at: file) }
            // Deepest paths first so a directory is empty by the time we remove it.
            for path in createdDirs.sorted(by: { $0.count > $1.count }) {
                try? fm.removeItem(atPath: path)
            }
        }

        do {
            let archiveSize = try fileSize(of: archive)
            let entries = try readCentralDirectory(handle: handle, archiveSize: archiveSize)

            var extractedTotal: UInt64 = 0
            for entry in entries {
                // A directory entry (trailing slash, zero size) carries no data; validate
                // its name and materialize the folder.
                if entry.name.hasSuffix("/") {
                    let dir = try sanitizedDestination(entry.name, within: directory)
                    try makeDirectory(dir)
                    continue
                }

                guard entry.method == 0 else {
                    throw ZipError.unsupportedEntry("\(entry.name): compression method \(entry.method) (only stored/0 is supported)")
                }
                guard entry.flags & 0x0001 == 0 else {
                    throw ZipError.unsupportedEntry("\(entry.name): entry is encrypted")
                }
                guard entry.compressedSize == entry.uncompressedSize else {
                    throw ZipError.malformed("\(entry.name): stored entry with mismatched sizes")
                }
                guard entry.compressedSize <= maxEntrySize else {
                    throw ZipError.entryTooLarge("\(entry.name): \(entry.compressedSize) bytes exceeds the 4 GiB limit")
                }
                extractedTotal += entry.compressedSize
                guard extractedTotal <= maxTotalSize else {
                    throw ZipError.entryTooLarge("archive total exceeds the \(maxTotalSize)-byte cap")
                }

                let destination = try sanitizedDestination(entry.name, within: directory)
                try makeDirectory(destination.deletingLastPathComponent())

                // Seek to the entry's local header, skip its (possibly different) name/extra
                // fields, then stream `compressedSize` bytes into the destination while
                // recomputing the CRC.
                try handle.seek(toOffset: entry.localHeaderOffset)
                let localFixed = try readExactly(30, from: handle, context: "\(entry.name): local header")
                guard localFixed.readLE32(at: 0) == localHeaderSignature else {
                    throw ZipError.malformed("\(entry.name): bad local header signature")
                }
                let localNameLen = UInt64(localFixed.readLE16(at: 26))
                let localExtraLen = UInt64(localFixed.readLE16(at: 28))
                try handle.seek(toOffset: entry.localHeaderOffset + 30 + localNameLen + localExtraLen)

                createdFiles.append(destination)
                let crc = try streamExtract(entry.compressedSize, from: handle, to: destination)
                guard crc == entry.crc else {
                    throw ZipError.crcMismatch("\(entry.name): CRC-32 mismatch (expected \(entry.crc), got \(crc))")
                }
            }
        } catch {
            cleanUp()
            throw error
        }
    }

    // MARK: - Central directory parsing

    /// A parsed central-directory record — everything ``unzip(_:to:)`` needs.
    private struct CentralEntry {
        var name: String
        var flags: UInt16
        var method: UInt16
        var crc: UInt32
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
    }

    /// Finds and parses the EOCD, then reads every central-directory record.
    private static func readCentralDirectory(handle: FileHandle, archiveSize: UInt64) throws -> [CentralEntry] {
        // The EOCD sits at the very end (22 bytes + an optional ≤ 65535-byte comment).
        // Read the tail and scan backwards for its signature.
        let maxTail = UInt64(22 + 0xFFFF)
        let tailLen = min(archiveSize, maxTail)
        guard tailLen >= 22 else { throw ZipError.malformed("archive too small to contain an EOCD") }
        try handle.seek(toOffset: archiveSize - tailLen)
        let tail = try readExactly(Int(tailLen), from: handle, context: "EOCD tail")

        guard let eocdOffset = lastIndexOfSignature(eocdSignature, in: tail) else {
            throw ZipError.malformed("end-of-central-directory record not found")
        }
        guard eocdOffset + 22 <= tail.count else {
            throw ZipError.malformed("truncated EOCD record")
        }
        let totalEntries = tail.readLE16(at: eocdOffset + 10)
        let cdSize = UInt64(tail.readLE32(at: eocdOffset + 12))
        let cdOffset = UInt64(tail.readLE32(at: eocdOffset + 16))
        // Cap the claimed central-directory size *before* allocating for it, so a crafted
        // EOCD can't make us read up to the whole file into memory.
        guard cdSize <= maxCentralDirectorySize else {
            throw ZipError.malformed("central directory size \(cdSize) exceeds the \(maxCentralDirectorySize)-byte cap")
        }
        guard cdOffset + cdSize <= archiveSize else {
            throw ZipError.malformed("central directory extends past end of file")
        }

        // The central directory is metadata (small); read it in one shot.
        try handle.seek(toOffset: cdOffset)
        let cd = try readExactly(Int(cdSize), from: handle, context: "central directory")

        var entries: [CentralEntry] = []
        var p = 0
        for _ in 0..<totalEntries {
            guard p + 46 <= cd.count else {
                throw ZipError.malformed("central directory record truncated")
            }
            guard cd.readLE32(at: p) == centralHeaderSignature else {
                throw ZipError.malformed("bad central directory signature")
            }
            let flags = cd.readLE16(at: p + 8)
            let method = cd.readLE16(at: p + 10)
            let crc = cd.readLE32(at: p + 16)
            let compSize = UInt64(cd.readLE32(at: p + 20))
            let uncompSize = UInt64(cd.readLE32(at: p + 24))
            let nameLen = Int(cd.readLE16(at: p + 28))
            let extraLen = Int(cd.readLE16(at: p + 30))
            let commentLen = Int(cd.readLE16(at: p + 32))
            let localOffset = UInt64(cd.readLE32(at: p + 42))
            guard p + 46 + nameLen <= cd.count else {
                throw ZipError.malformed("central directory name field truncated")
            }
            let nameData = cd.subdata(in: (p + 46)..<(p + 46 + nameLen))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw ZipError.malformed("entry name is not valid UTF-8")
            }
            entries.append(CentralEntry(
                name: name,
                flags: flags,
                method: method,
                crc: crc,
                compressedSize: compSize,
                uncompressedSize: uncompSize,
                localHeaderOffset: localOffset
            ))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    /// Scans `data` from the end for the little-endian 4-byte `signature`, returning the
    /// index of its first byte (used to locate the EOCD, which may be followed by a
    /// comment).
    private static func lastIndexOfSignature(_ signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 4 else { return nil }
        var i = data.count - 4
        while i >= 0 {
            if data.readLE32(at: i) == signature { return i }
            i -= 1
        }
        return nil
    }

    // MARK: - Path safety (zip-slip)

    /// Resolves an entry name to a destination URL and proves it stays inside
    /// `directory`. Rejects absolute paths, backslashes, empty/dot-only names, and any
    /// `..` component, then verifies the standardized result is still contained.
    ///
    /// The containment check is **lexical** (no symlink resolution): it is sound because
    /// ``unzip(_:to:)`` requires a fresh, empty destination, so no pre-existing symlink
    /// component can be traversed and every component is one we create as a plain
    /// directory/file.
    private static func sanitizedDestination(_ name: String, within directory: URL) throws -> URL {
        if name.hasPrefix("/") {
            throw ZipError.malformed("entry '\(name)' is an absolute path")
        }
        if name.contains("\\") {
            throw ZipError.malformed("entry '\(name)' contains a backslash")
        }
        let components = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Reject empty ("") or dot-only (".", "./.", …) names up front: they resolve to
        // the destination directory itself and would otherwise fail later with a
        // confusing "cannot open for writing".
        if components.allSatisfy({ $0 == "." }) {
            throw ZipError.malformed("entry '\(name)' has no usable path component")
        }
        // Resolve the destination's symlinks ONCE, up front, and build every entry path
        // by appending to that already-resolved base. This is what keeps the containment
        // check symmetric.
        //
        // The subtle bug this fixes (a valid backup that failed to restore only on device):
        // `standardizedFileURL` — and `resolvingSymlinksInPath()` — resolve the `/private`
        // symlink only for paths that already EXIST on disk. On a real device the temp
        // destination lives under `/var` (a symlink to `/private/var`), so the destination
        // directory, which exists, resolved to `/private/var/…/dest`, while an entry path
        // whose leaf doesn't exist yet (e.g. `manifest.json`, not extracted) stayed
        // `/var/…/dest/manifest.json`. The prefix check then rejected a perfectly valid
        // entry as "outside the destination". The simulator's temp path isn't symlinked
        // that way, so it never reproduced there. Resolving the base once and appending to
        // it removes the existing-vs-missing asymmetry entirely (verified on macOS: a
        // symlinked destination round-trips, and a `..` entry is still rejected).
        let base = directory.resolvingSymlinksInPath()
        var url = base
        for component in components {
            if component == ".." {
                throw ZipError.malformed("entry '\(name)' escapes the destination via '..'")
            }
            if component == "." { continue }
            url.appendPathComponent(component)
        }
        // Belt-and-braces lexical containment (the `..` components are already rejected
        // above): both paths derive from the same resolved base, so this is symmetric.
        let basePath = base.standardizedFileURL.path
        let resolvedPath = url.standardizedFileURL.path
        guard resolvedPath == basePath || resolvedPath.hasPrefix(basePath + "/") else {
            throw ZipError.malformed("entry '\(name)' resolves outside the destination")
        }
        return url
    }

    // MARK: - Streaming helpers

    /// Copies the whole file at `url` into the already-open output handle in chunks.
    private static func streamFile(at url: URL, into out: FileHandle) throws {
        guard let input = try? FileHandle(forReadingFrom: url) else {
            throw ZipError.malformed("cannot open \(url.lastPathComponent) for reading")
        }
        defer { try? input.close() }
        while true {
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            try out.write(contentsOf: chunk)
        }
    }

    /// Streams exactly `count` bytes from `handle` into a new file at `destination`,
    /// returning their CRC-32. Throws if the source runs short.
    private static func streamExtract(_ count: UInt64, from handle: FileHandle, to destination: URL) throws -> UInt32 {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: destination) else {
            throw ZipError.malformed("cannot open \(destination.lastPathComponent) for writing")
        }
        defer { try? out.close() }

        var crc = CRC32()
        var remaining = count
        while remaining > 0 {
            let want = Int(min(UInt64(chunkSize), remaining))
            let chunk = try handle.read(upToCount: want) ?? Data()
            if chunk.isEmpty {
                throw ZipError.malformed("entry data truncated (\(remaining) bytes short)")
            }
            crc.update(chunk)
            try out.write(contentsOf: chunk)
            remaining -= UInt64(chunk.count)
        }
        return crc.checksum
    }

    /// Reads exactly `count` bytes from `handle`, looping over short reads; throws a
    /// malformed error tagged with `context` if EOF arrives first.
    private static func readExactly(_ count: Int, from handle: FileHandle, context: String) throws -> Data {
        var buffer = Data()
        buffer.reserveCapacity(count)
        while buffer.count < count {
            let chunk = try handle.read(upToCount: count - buffer.count) ?? Data()
            if chunk.isEmpty {
                throw ZipError.malformed("\(context): unexpected end of file")
            }
            buffer.append(chunk)
        }
        return buffer
    }

    // MARK: - CRC-32 over a file

    /// Streams the file at `url` through a CRC-32, never loading it whole.
    private static func crc32(ofFileAt url: URL) throws -> UInt32 {
        guard let input = try? FileHandle(forReadingFrom: url) else {
            throw ZipError.malformed("cannot open \(url.lastPathComponent) for CRC")
        }
        defer { try? input.close() }
        var crc = CRC32()
        while true {
            let chunk = try input.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            crc.update(chunk)
        }
        return crc.checksum
    }

    // MARK: - Filesystem helpers

    /// Returns every regular file under `directory` as sorted POSIX relative paths.
    private static func regularFiles(under directory: URL) throws -> [String] {
        let fm = FileManager.default
        let base = directory.standardizedFileURL
        guard let enumerator = fm.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        var result: [String] = []
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let full = url.standardizedFileURL.path
            guard full.hasPrefix(basePath) else { continue }
            result.append(String(full.dropFirst(basePath.count)))
        }
        return result.sorted()
    }

    private static func fileSize(of url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private static func modificationDate(of url: URL) -> Date {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.modificationDate] as? Date) ?? Date()
    }

    /// Converts a `Date` to the MS-DOS packed time/date the zip format uses. DOS dates
    /// start at 1980 and have 2-second resolution; anything before 1980 clamps to it.
    private static func dosDateTime(from date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, c.year ?? 1980)
        let dosDate = UInt16(((year - 1980) & 0x7F) << 9 | ((c.month ?? 1) & 0x0F) << 5 | ((c.day ?? 1) & 0x1F))
        let dosTime = UInt16(((c.hour ?? 0) & 0x1F) << 11 | ((c.minute ?? 0) & 0x3F) << 5 | (((c.second ?? 0) / 2) & 0x1F))
        return (dosTime, dosDate)
    }
}

// MARK: - CRC-32

/// Incremental CRC-32 (IEEE polynomial `0xEDB88320`, reflected) — the checksum the
/// zip format mandates. Fed chunk-by-chunk so we never buffer a whole file.
private struct CRC32 {
    /// Precomputed byte table for the reflected polynomial.
    private static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var s = state
        for byte in data {
            s = CRC32.table[Int((s ^ UInt32(byte)) & 0xFF)] ^ (s >> 8)
        }
        state = s
    }

    var checksum: UInt32 { state ^ 0xFFFF_FFFF }
}

// MARK: - Little-endian (de)serialization

private extension Data {
    /// Appends a little-endian `UInt16`.
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    /// Appends a little-endian `UInt32`.
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }

    /// Reads a little-endian `UInt16` at `offset` (relative to `startIndex`). Assumes
    /// the caller has bounds-checked; used only after explicit length guards.
    func readLE16(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | (UInt16(self[i + 1]) << 8)
    }

    /// Reads a little-endian `UInt32` at `offset` (relative to `startIndex`).
    func readLE32(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i])
            | (UInt32(self[i + 1]) << 8)
            | (UInt32(self[i + 2]) << 16)
            | (UInt32(self[i + 3]) << 24)
    }
}
