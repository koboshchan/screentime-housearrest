import Foundation
import zlib

public struct SEGBRecord: Identifiable {
    public let id = UUID()
    public var state: UInt32
    public var timestamp: Double // Cocoa timestamp
    public var flag: UInt32
    public var payload: Data

    public init(state: UInt32 = 1, timestamp: Double, flag: UInt32 = 0, payload: Data) {
        self.state = state
        self.timestamp = timestamp
        self.flag = flag
        self.payload = payload
    }
}

public struct SEGBHeader {
    public var count: UInt32
    public var creationTimestamp: Double
    public var version: UInt32
    public var flag1: UInt32
    public var flag2: UInt64
    public var totalSize: Int

    public init(count: UInt32, creationTimestamp: Double, version: UInt32 = 10, flag1: UInt32 = 0xFFFFFFFF, flag2: UInt64 = 0, totalSize: Int = 524288) {
        self.count = count
        self.creationTimestamp = creationTimestamp
        self.version = version
        self.flag1 = flag1
        self.flag2 = flag2
        self.totalSize = totalSize
    }
}

public enum SEGBV2 {
    public static func crc32Checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.bindMemory(to: Bytef.self).baseAddress else { return 0 }
            return UInt32(crc32(0, ptr, uInt(buffer.count)))
        }
    }

    public static func parse(data: Data) throws -> (SEGBHeader, [SEGBRecord]) {
        guard data.count >= 32 else {
            throw NSError(domain: "SEGB", code: 1, userInfo: [NSLocalizedDescriptionKey: "File too small (<32 bytes)"])
        }

        let magic = data.subdata(in: 0..<4)
        guard magic == Data([0x53, 0x45, 0x47, 0x42]) else { // "SEGB"
            throw NSError(domain: "SEGB", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid SEGB magic"])
        }

        let count = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) }
        let cTs = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: Double.self) }
        let ver = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 16, as: UInt32.self) }
        let f1 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 20, as: UInt32.self) }
        let f2 = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 24, as: UInt64.self) }

        guard ver == 10 else {
            throw NSError(domain: "SEGB", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsupported SEGB version \(ver)"])
        }

        let header = SEGBHeader(count: count, creationTimestamp: cTs, version: ver, flag1: f1, flag2: f2, totalSize: data.count)
        var records: [SEGBRecord] = []
        var prevEnd = 0

        for i in 0..<Int(count) {
            let footerPos = data.count - 16 * (i + 1)
            guard footerPos >= 32 else { break }

            let endOff = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: footerPos, as: UInt32.self) })
            let state = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: footerPos + 4, as: UInt32.self) }
            let ts = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: footerPos + 8, as: Double.self) }

            let alOff = (prevEnd + 3) & ~3

            if state == 1 {
                guard 32 + alOff + 8 <= 32 + endOff && 32 + endOff <= data.count else {
                    continue
                }
                let storedCrc = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32 + alOff, as: UInt32.self) }
                let flag = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 32 + alOff + 4, as: UInt32.self) }
                let pb = data.subdata(in: (32 + alOff + 8)..<(32 + endOff))
                let calcCrc = crc32Checksum(pb)
                if calcCrc != storedCrc {
                    print("[SEGB] Warning: CRC mismatch at record \(i)")
                }
                records.append(SEGBRecord(state: state, timestamp: ts, flag: flag, payload: pb))
            } else {
                let pb: Data
                if endOff > alOff && 32 + endOff <= data.count {
                    pb = data.subdata(in: (32 + alOff)..<(32 + endOff))
                } else {
                    pb = Data()
                }
                records.append(SEGBRecord(state: state, timestamp: ts, flag: 0, payload: pb))
            }
            if endOff > 0 {
                prevEnd = endOff
            }
        }

        return (header, records)
    }

    public static func build(header: SEGBHeader, records: [SEGBRecord]) -> Data {
        var buf = Data(count: header.totalSize)

        // Write header (32 bytes)
        buf.withUnsafeMutableBytes { ptr in
            ptr.storeBytes(of: 0x42474553 as UInt32, toByteOffset: 0, as: UInt32.self) // "SEGB"
            ptr.storeBytes(of: UInt32(records.count), toByteOffset: 4, as: UInt32.self)
            ptr.storeBytes(of: header.creationTimestamp, toByteOffset: 8, as: Double.self)
            ptr.storeBytes(of: header.version, toByteOffset: 16, as: UInt32.self)
            ptr.storeBytes(of: header.flag1, toByteOffset: 20, as: UInt32.self)
            ptr.storeBytes(of: header.flag2, toByteOffset: 24, as: UInt64.self)
        }

        var prevEnd = 0
        for (i, rec) in records.enumerated() {
            let alOff = (prevEnd + 3) & ~3
            let endOff: Int

            if rec.state == 1 {
                let crc = crc32Checksum(rec.payload)
                buf.withUnsafeMutableBytes { ptr in
                    ptr.storeBytes(of: crc, toByteOffset: 32 + alOff, as: UInt32.self)
                    ptr.storeBytes(of: rec.flag, toByteOffset: 32 + alOff + 4, as: UInt32.self)
                }
                buf.replaceSubrange((32 + alOff + 8)..<(32 + alOff + 8 + rec.payload.count), with: rec.payload)
                endOff = alOff + 8 + rec.payload.count
            } else {
                if rec.payload.isEmpty {
                    endOff = 0
                } else {
                    buf.replaceSubrange((32 + alOff)..<(32 + alOff + rec.payload.count), with: rec.payload)
                    endOff = alOff + rec.payload.count
                }
            }

            let footerPos = header.totalSize - 16 * (i + 1)
            buf.withUnsafeMutableBytes { ptr in
                ptr.storeBytes(of: UInt32(endOff), toByteOffset: footerPos, as: UInt32.self)
                ptr.storeBytes(of: rec.state, toByteOffset: footerPos + 4, as: UInt32.self)
                ptr.storeBytes(of: rec.timestamp, toByteOffset: footerPos + 8, as: Double.self)
            }
            if endOff > 0 {
                prevEnd = endOff
            }
        }

        return buf
    }

    // MARK: - Protobuf Encoders

    public static func encodeAppUsage(cocoaTs: Double, starting: Bool, bundleId: String, isTrusted: Bool = true) -> Data {
        let unixTs = cocoaTs + 978307200.0
        var d = Data()
        // Field 1: varint starting (0x08 0x01 or 0x08 0x00)
        d.append(contentsOf: [0x08, starting ? 0x01 : 0x00])
        // Field 2: fixed64 unix_ts (0x11 <8 bytes double>)
        d.append(0x11)
        var ts = unixTs
        d.append(Data(bytes: &ts, count: 8))
        // Field 3: string bundleId (0x1a <length> <utf8>)
        let bData = bundleId.data(using: .utf8) ?? Data()
        d.append(0x1a)
        d.append(UInt8(bData.count))
        d.append(bData)
        // Field 5: varint isUsageTrusted (0x28 0x01)
        d.append(contentsOf: [0x28, isTrusted ? 0x01 : 0x00])
        return d
    }

    public static func decodeAppUsage(payload: Data) -> (starting: Bool, unixTs: Double, bundleId: String)? {
        guard payload.count >= 13 else { return nil }
        guard payload[0] == 0x08 else { return nil }
        let starting = payload[1] != 0
        guard payload[2] == 0x11 else { return nil }
        let unixTs = payload.subdata(in: 3..<11).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        guard payload[11] == 0x1a else { return nil }
        let strLen = Int(payload[12])
        guard payload.count >= 13 + strLen else { return nil }
        let strData = payload.subdata(in: 13..<(13 + strLen))
        let bundleId = String(data: strData, encoding: .utf8) ?? ""
        return (starting, unixTs, bundleId)
    }

    public static func encodeBacklight(cocoaTs: Double, level: UInt8) -> Data {
        var d = Data()
        // Field 1: fixed64 cocoa_ts (0x09 <8 bytes double>)
        d.append(0x09)
        var ts = cocoaTs
        d.append(Data(bytes: &ts, count: 8))
        // Field 2: varint level (0x10 <1 byte level>)
        d.append(contentsOf: [0x10, level])
        return d
    }

    public static func decodeBacklight(payload: Data) -> (cocoaTs: Double, level: UInt8)? {
        guard payload.count >= 11 else { return nil }
        guard payload[0] == 0x09 else { return nil }
        let cocoaTs = payload.subdata(in: 1..<9).withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
        guard payload[9] == 0x10 else { return nil }
        let level = payload[10]
        return (cocoaTs, level)
    }
}
