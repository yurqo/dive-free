import Foundation

/// Builds a Garmin **FIT** activity file from a session's surface track plus its
/// depth, heart-rate, and water-temperature series. FIT is the only single-file
/// format that carries **both** a `total_calories` figure (which GPX can't)
/// **and** a per-point temperature stream (which TCX can't) — so the dive's
/// calories and water-temperature graph both ride along.
///
/// Every `record` needs a position, so the builder returns `nil` when the
/// session has no position source (no track and no tagged location) or no
/// time-series data at all — the caller then falls back to a text-only summary.
///
/// Depth has no FIT concept, so it's mapped to (negative) `altitude`. The sport
/// is set to `swimming`.
///
/// Layout: a 14-byte header, then definition+data messages for `file_id`,
/// `record` (the time series), `lap`, `session` (carries `total_calories` +
/// `sport`), and `activity`, then the 2-byte file CRC. Field/message numbers
/// follow the FIT global profile.
public enum FITExport {
    /// FIT timestamps count seconds from 1989-12-31 00:00:00 UTC.
    private static let fitEpoch = Date(timeIntervalSince1970: 631_065_600)

    public static func build(_ session: DiveSession) -> Data? {
        let hasPosition = !session.track.isEmpty || session.location != nil
        let hasSeries = session.dives.contains { !$0.samples.isEmpty }
            || !session.heartRateSamples.isEmpty
            || !session.temperatureSamples.isEmpty
        guard hasPosition, hasSeries else { return nil }

        // Merge every source's instants into one time-ordered set of records.
        var instants = Set<Date>()
        instants.formUnion(session.track.map(\.timestamp))
        for dive in session.dives { instants.formUnion(dive.samples.map(\.timestamp)) }
        instants.formUnion(session.heartRateSamples.map(\.timestamp))
        instants.formUnion(session.temperatureSamples.map(\.timestamp))
        let times = instants.sorted()
        guard !times.isEmpty else { return nil }

        let heartRate = session.heartRateSamples
            .sorted { $0.timestamp < $1.timestamp }.map { ($0.timestamp, $0.bpm) }
        let temperature = session.temperatureSamples
            .sorted { $0.timestamp < $1.timestamp }.map { ($0.timestamp, $0.celsius) }
        // Clean the surface track once; every record interpolates against it, so
        // recomputing it per instant would re-run the Kalman smoother O(records).
        let track = session.effectiveTrack

        let start = session.startTime
        let end = session.endTime ?? times.last ?? start
        let elapsedMillis = UInt32(clamping: Int((max(0, end.timeIntervalSince(start)) * 1000).rounded()))
        let calories = UInt16(clamping: Int((session.activeEnergyKilocalories ?? 0).rounded()))

        var w = Writer()

        // file_id (global 0): type=activity(4), manufacturer=development(255), product, time_created.
        w.definition(local: 0, global: 0, fields: [(0, 1, .enum), (1, 2, .uint16), (2, 2, .uint16), (4, 4, .uint32)])
        w.dataHeader(local: 0)
        w.u8(4); w.u16(255); w.u16(0); w.u32(timestamp(start))

        // record (global 20): timestamp, position_lat/long (semicircles), altitude, heart_rate, temperature.
        w.definition(local: 1, global: 20, fields: [
            (253, 4, .uint32), (0, 4, .sint32), (1, 4, .sint32), (2, 2, .uint16), (3, 1, .uint8), (13, 1, .sint8),
        ])
        for time in times {
            guard let position = DiveSession.surfacePosition(in: track, at: time) ?? session.location else { continue }
            let depth = depthMeters(in: session, at: time)
            w.dataHeader(local: 1)
            w.u32(timestamp(time))
            w.i32(semicircles(position.latitude))
            w.i32(semicircles(position.longitude))
            w.u16(altitude(depth > 0 ? -depth : 0))
            w.u8(heartRateByte(interpolate(heartRate, at: time)))   // 0xFF = invalid/absent
            w.i8(temperatureByte(interpolate(temperature, at: time))) // 0x7F = invalid/absent
        }

        // lap (global 19): carries calories too (some parsers read it here).
        w.definition(local: 2, global: 19, fields: [
            (253, 4, .uint32), (2, 4, .uint32), (7, 4, .uint32), (8, 4, .uint32), (11, 2, .uint16),
        ])
        w.dataHeader(local: 2)
        w.u32(timestamp(end)); w.u32(timestamp(start)); w.u32(elapsedMillis); w.u32(elapsedMillis); w.u16(calories)

        // session (global 18): parsers read total_calories + sport from here.
        w.definition(local: 3, global: 18, fields: [
            (253, 4, .uint32), (2, 4, .uint32), (7, 4, .uint32), (8, 4, .uint32), (11, 2, .uint16), (5, 1, .enum),
        ])
        w.dataHeader(local: 3)
        w.u32(timestamp(end)); w.u32(timestamp(start)); w.u32(elapsedMillis); w.u32(elapsedMillis)
        w.u16(calories); w.u8(5) // sport = swimming

        // activity (global 34): one session, manual, stop.
        w.definition(local: 4, global: 34, fields: [
            (253, 4, .uint32), (0, 4, .uint32), (1, 2, .uint16), (2, 1, .enum), (3, 1, .enum), (4, 1, .enum),
        ])
        w.dataHeader(local: 4)
        w.u32(timestamp(end)); w.u32(elapsedMillis); w.u16(1); w.u8(0); w.u8(26); w.u8(1) // type=manual, event=activity, event_type=stop

        return assemble(body: w.bytes)
    }

    // MARK: - File assembly

    /// Wraps the data records in the 14-byte header (with header CRC) and the
    /// trailing file CRC.
    private static func assemble(body: [UInt8]) -> Data {
        var header: [UInt8] = [14, 0x20]            // header size, protocol version 2.0
        header += le16(2140)                         // profile version
        header += le32(UInt32(body.count))           // data size (records only)
        header += Array("\u{2E}FIT".utf8)            // ".FIT"
        header += le16(crc16(Array(header[0..<12]))) // header CRC over the first 12 bytes

        var file = header + body
        file += le16(crc16(file))                    // file CRC over header + records
        return Data(file)
    }

    // MARK: - Field encoders

    private static func timestamp(_ date: Date) -> UInt32 {
        UInt32(clamping: Int(date.timeIntervalSince(fitEpoch).rounded()))
    }

    /// Degrees → FIT semicircles (1 semicircle = 180° / 2³¹).
    private static func semicircles(_ degrees: Double) -> Int32 {
        Int32(clamping: Int64((degrees * (2_147_483_648.0 / 180.0)).rounded()))
    }

    /// Meters → FIT `altitude` (uint16, scale 5, offset 500): stored = (m+500)·5.
    private static func altitude(_ meters: Double) -> UInt16 {
        UInt16(clamping: Int(((meters + 500) * 5).rounded()))
    }

    /// bpm → uint8, or 0xFF (the FIT "invalid" sentinel) when absent.
    private static func heartRateByte(_ bpm: Double?) -> UInt8 {
        guard let bpm else { return 0xFF }
        return UInt8(clamping: Int(bpm.rounded()))
    }

    /// °C → sint8 byte, or 0x7F (the FIT "invalid" sentinel) when absent.
    private static func temperatureByte(_ celsius: Double?) -> UInt8 {
        guard let celsius else { return 0x7F }
        return UInt8(bitPattern: Int8(clamping: Int(celsius.rounded())))
    }

    // MARK: - Shared interpolation (also used by the tests)

    /// Depth (m, positive down) at an instant: interpolated within whatever dive
    /// contains it, else 0 (at the surface).
    static func depthMeters(in session: DiveSession, at time: Date) -> Double {
        for dive in session.dives where time >= dive.startTime && time <= dive.endTime {
            if let depth = dive.interpolatedDepth(at: time) { return depth }
        }
        return 0
    }

    /// Linearly-interpolated value over time-ordered `(date, value)` pairs,
    /// clamped to the endpoints; `nil` when there are no samples.
    static func interpolate(_ samples: [(Date, Double)], at time: Date) -> Double? {
        guard let first = samples.first, let last = samples.last else { return nil }
        if time <= first.0 { return first.1 }
        if time >= last.0 { return last.1 }
        for (a, b) in zip(samples, samples.dropFirst()) where time >= a.0 && time <= b.0 {
            let span = b.0.timeIntervalSince(a.0)
            guard span > 0 else { return a.1 }
            let fraction = time.timeIntervalSince(a.0) / span
            return a.1 + (b.1 - a.1) * fraction
        }
        return last.1
    }

    // MARK: - Little-endian helpers

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }
    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    // MARK: - FIT CRC-16

    private static let crcTable: [UInt16] = [
        0x0000, 0xCC01, 0xD801, 0x1400, 0xF001, 0x3C00, 0x2800, 0xE401,
        0xA001, 0x6C00, 0x7800, 0xB401, 0x5000, 0x9C01, 0x8801, 0x4400,
    ]

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            var tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int(byte & 0xF)]
            tmp = crcTable[Int(crc & 0xF)]
            crc = (crc >> 4) & 0x0FFF
            crc = crc ^ tmp ^ crcTable[Int((byte >> 4) & 0xF)]
        }
        return crc
    }

    // MARK: - Record writer

    /// FIT base types used here (the high bit flags multi-byte/endian types).
    enum BaseType: UInt8 {
        case `enum` = 0x00, sint8 = 0x01, uint8 = 0x02, uint16 = 0x84, sint32 = 0x85, uint32 = 0x86
    }

    /// Accumulates FIT records (definition + data messages) into a byte buffer.
    private struct Writer {
        var bytes: [UInt8] = []

        /// Definition message: header `0x40 | local`, reserved, little-endian arch,
        /// global message number, field count, then `(num, size, baseType)` triples.
        mutating func definition(local: UInt8, global: UInt16, fields: [(UInt8, UInt8, BaseType)]) {
            bytes.append(0x40 | local)
            bytes.append(0)                // reserved
            bytes.append(0)                // architecture: little-endian
            bytes += FITExport.le16(global)
            bytes.append(UInt8(fields.count))
            for (num, size, base) in fields { bytes += [num, size, base.rawValue] }
        }

        /// Data message header for a previously-defined local message type.
        mutating func dataHeader(local: UInt8) { bytes.append(local) }

        mutating func u8(_ v: UInt8) { bytes.append(v) }
        mutating func i8(_ v: UInt8) { bytes.append(v) } // already a raw sint8 byte pattern
        mutating func u16(_ v: UInt16) { bytes += FITExport.le16(v) }
        mutating func u32(_ v: UInt32) { bytes += FITExport.le32(v) }
        mutating func i32(_ v: Int32) { bytes += FITExport.le32(UInt32(bitPattern: v)) }
    }
}
