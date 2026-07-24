import Foundation
import Testing
@testable import Domain

/// Byte-golden coverage for the pure `FITExport` encoder: it builds a fixture
/// session and walks the emitted bytes with a minimal test-only decoder,
/// validating the FIT framing (header, `.FIT` signature, both CRCs) and the
/// message contents (file_id, record stream, session/lap calories + sport). This
/// locks the exact output the Strava upload path relies on.
@Suite("FITExport")
struct FITExportTests {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func diveWithProfile() -> Dive {
        Dive(
            startTime: t0.addingTimeInterval(10), endTime: t0.addingTimeInterval(40), maxDepthMeters: 12,
            samples: [
                DepthSample(timestamp: t0.addingTimeInterval(10), depthMeters: 0),
                DepthSample(timestamp: t0.addingTimeInterval(25), depthMeters: 12),
                DepthSample(timestamp: t0.addingTimeInterval(40), depthMeters: 0),
            ]
        )
    }

    @Test("returns nil with no position source")
    func nilWithoutPosition() {
        let session = DiveSession(startTime: t0, dives: [diveWithProfile()])
        #expect(FITExport.build(session) == nil)
    }

    @Test("returns nil with a position but no time-series data")
    func nilWithoutSeries() {
        let session = DiveSession(startTime: t0, location: GeoPoint(latitude: 1, longitude: 2))
        #expect(FITExport.build(session) == nil)
    }

    @Test("emits the FIT header signature and a round-tripping file CRC")
    func headerAndCRC() throws {
        let session = DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(60),
            location: GeoPoint(latitude: 1, longitude: 2),
            heartRateSamples: [HeartRateSample(timestamp: t0, bpm: 70)]
        )
        let data = try #require(FITExport.build(session))
        let bytes = [UInt8](data)
        #expect(bytes.count >= 16)
        #expect(bytes[0] == 14)                                   // header size
        #expect(Array(bytes[8..<12]) == Array(".FIT".utf8))       // signature at offset 8..11
        let fit = try #require(FITDecoder.decode(data), "structurally valid FIT")
        #expect(fit.headerCRCOK)
        #expect(fit.fileCRCOK)
    }

    @Test("builds a FIT with track, depth, heart-rate, temperature, and calories")
    func buildsFullFIT() throws {
        let session = DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(100),
            dives: [diveWithProfile()],
            location: GeoPoint(latitude: 20.5, longitude: -87.0),
            track: [
                TrackPoint(timestamp: t0, location: GeoPoint(latitude: 20.5, longitude: -87.0)),
                TrackPoint(timestamp: t0.addingTimeInterval(100), location: GeoPoint(latitude: 20.6, longitude: -87.1)),
            ],
            heartRateSamples: [
                HeartRateSample(timestamp: t0, bpm: 70),
                HeartRateSample(timestamp: t0.addingTimeInterval(100), bpm: 90),
            ],
            temperatureSamples: [
                TemperatureSample(timestamp: t0.addingTimeInterval(10), celsius: 21),
            ],
            activeEnergyKilocalories: 123.4
        )
        let data = try #require(FITExport.build(session))
        let fit = try #require(FITDecoder.decode(data), "structurally valid FIT")
        #expect(fit.headerCRCOK)
        #expect(fit.fileCRCOK)

        // file_id (msg 0) declares an activity (type = 4).
        let fileID = try #require(fit.messages.first { $0.globalNum == 0 })
        #expect(fileID.u8(0) == 4)

        // session (msg 18) carries the rounded calories + swimming sport (5).
        let sessionMsg = try #require(fit.messages.first { $0.globalNum == 18 })
        #expect(sessionMsg.u16(11) == 123)
        #expect(sessionMsg.u8(5) == 5)

        // lap (19) and activity (34) messages are present.
        #expect(fit.messages.contains { $0.globalNum == 19 })
        #expect(fit.messages.contains { $0.globalNum == 34 })

        // One record (msg 20) per distinct instant (t0, +10, +25, +40, +100),
        // each positioned; the deepest carries altitude, plus the HR + temp streams.
        let records = fit.messages.filter { $0.globalNum == 20 }
        #expect(records.count == 5)
        #expect(records.allSatisfy { $0.i32(0) != nil && $0.i32(1) != nil })
        #expect(records.contains { $0.u16(2) == 2440 }) // depth 12 m → (−12+500)·5
        #expect(records.contains { $0.u8(3) == 70 })     // heart rate
        #expect(records.contains { $0.i8(13) == 21 })    // water temperature
    }

    @Test("builds from a fixed location with zero calories when energy is unknown")
    func buildsFromFixedLocation() throws {
        let session = DiveSession(
            startTime: t0,
            endTime: t0.addingTimeInterval(60),
            location: GeoPoint(latitude: 1, longitude: 2),
            heartRateSamples: [
                HeartRateSample(timestamp: t0, bpm: 70),
                HeartRateSample(timestamp: t0.addingTimeInterval(60), bpm: 80),
            ]
        )
        let data = try #require(FITExport.build(session))
        let fit = try #require(FITDecoder.decode(data))
        let sessionMsg = try #require(fit.messages.first { $0.globalNum == 18 })
        #expect(sessionMsg.u16(11) == 0) // no active energy → 0 kcal
        let records = fit.messages.filter { $0.globalNum == 20 }
        #expect(!records.isEmpty)
        // No temperature samples → every record uses the FIT sint8 "invalid" sentinel.
        #expect(records.allSatisfy { $0.fields[13] == [0x7F] })
    }

    @Test("depthMeters is zero at the surface and the sampled depth underwater")
    func depthAtInstant() {
        let session = DiveSession(startTime: t0, dives: [diveWithProfile()])
        #expect(FITExport.depthMeters(in: session, at: t0) == 0)
        #expect(FITExport.depthMeters(in: session, at: t0.addingTimeInterval(25)) == 12)
    }

    @Test("interpolate clamps to endpoints and lerps between samples")
    func interpolates() {
        #expect(FITExport.interpolate([], at: t0) == nil)
        let samples = [(t0, 10.0), (t0.addingTimeInterval(10), 20.0)]
        #expect(FITExport.interpolate(samples, at: t0.addingTimeInterval(-5)) == 10)
        #expect(FITExport.interpolate(samples, at: t0.addingTimeInterval(5)) == 15)
        #expect(FITExport.interpolate(samples, at: t0.addingTimeInterval(50)) == 20)
    }
}

// MARK: - Minimal FIT decoder (test-only) to validate the encoder's bytes

/// A decoded FIT data message: its global message number and raw field bytes.
private struct FITMessage {
    let globalNum: UInt16
    let fields: [UInt8: [UInt8]]

    func u8(_ field: UInt8) -> UInt8? { fields[field]?.first }
    func i8(_ field: UInt8) -> Int8? { fields[field]?.first.map { Int8(bitPattern: $0) } }
    func u16(_ field: UInt8) -> UInt16? {
        guard let b = fields[field], b.count >= 2 else { return nil }
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }
    func i32(_ field: UInt8) -> Int32? {
        guard let b = fields[field], b.count >= 4 else { return nil }
        return Int32(bitPattern: UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24))
    }
}

/// Walks a FIT file: validates the header + both CRCs and decodes every data
/// message using the definition messages it carries. Returns nil on any
/// structural fault (so a malformed encoder output fails the test).
private enum FITDecoder {
    static func decode(_ data: Data) -> (messages: [FITMessage], headerCRCOK: Bool, fileCRCOK: Bool)? {
        let bytes = [UInt8](data)
        guard bytes.count >= 16, bytes[0] == 14,
              Array(bytes[8..<12]) == Array(".FIT".utf8) else { return nil }
        let dataSize = Int(UInt32(bytes[4]) | (UInt32(bytes[5]) << 8) | (UInt32(bytes[6]) << 16) | (UInt32(bytes[7]) << 24))
        guard 14 + dataSize + 2 == bytes.count else { return nil }

        let headerCRC = UInt16(bytes[12]) | (UInt16(bytes[13]) << 8)
        let headerCRCOK = headerCRC == FITExport.crc16(Array(bytes[0..<12]))
        let fileCRC = UInt16(bytes[bytes.count - 2]) | (UInt16(bytes[bytes.count - 1]) << 8)
        let fileCRCOK = fileCRC == FITExport.crc16(Array(bytes[0..<(bytes.count - 2)]))

        var definitions: [UInt8: (global: UInt16, fields: [(num: UInt8, size: Int)])] = [:]
        var messages: [FITMessage] = []
        var i = 14
        let end = 14 + dataSize
        while i < end {
            let header = bytes[i]; i += 1
            let local = header & 0x0F
            if header & 0x40 != 0 { // definition message
                guard i + 5 <= end else { return nil }
                let global = UInt16(bytes[i + 2]) | (UInt16(bytes[i + 3]) << 8)
                let count = Int(bytes[i + 4]); i += 5
                var fields: [(UInt8, Int)] = []
                for _ in 0..<count {
                    guard i + 3 <= end else { return nil }
                    fields.append((bytes[i], Int(bytes[i + 1]))); i += 3
                }
                definitions[local] = (global, fields)
            } else { // data message
                guard let def = definitions[local] else { return nil }
                var map: [UInt8: [UInt8]] = [:]
                for (num, size) in def.fields {
                    guard i + size <= end else { return nil }
                    map[num] = Array(bytes[i..<(i + size)]); i += size
                }
                messages.append(FITMessage(globalNum: def.global, fields: map))
            }
        }
        guard i == end else { return nil }
        return (messages, headerCRCOK, fileCRCOK)
    }
}
