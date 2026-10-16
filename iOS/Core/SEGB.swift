import Foundation
import zlib

public struct StorageFailure: Error, CustomStringConvertible {
    public let code: String
    public let description: String
    public init(_ code: String, _ message: String) { self.code = code; self.description = message }
}
func requireStorage(_ condition: Bool, _ message: String, _ code: String = "unsupported_format") throws {
    if !condition { throw StorageFailure(code, message) }
}
func validClock(_ value: Double) throws {
    try requireStorage(value.isFinite && value >= -978307200 && value <= 252423993599, "Invalid timestamp.")
}
extension Data {
    func le32(_ p: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(self[p + $1]) << ($1 * 8) } }
    func le64(_ p: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(self[p + $1]) << ($1 * 8) } }
    mutating func put32(_ v: UInt32, _ p: Int) { for i in 0..<4 { self[p+i] = UInt8(truncatingIfNeeded: v >> (i*8)) } }
    mutating func put64(_ v: UInt64, _ p: Int) { for i in 0..<8 { self[p+i] = UInt8(truncatingIfNeeded: v >> (i*8)) } }
}
public struct SegmentRecord {
    public var state: UInt32
    public var timestamp: Double
    public var flag: UInt32
    public var payload: Data
    public init(state: UInt32 = 1, timestamp: Double, flag: UInt32 = 0, payload: Data) {
        self.state = state; self.timestamp = timestamp; self.flag = flag; self.payload = payload
    }
}
public struct Segment {
    public static let maximumSize = 64 * 1024 * 1024
    public var created: Double
    public var flags: UInt32
    public var reserved: UInt64
    public var size: Int
    public var records: [SegmentRecord]
    public init(created: Double, flags: UInt32 = .max, reserved: UInt64 = 0, size: Int, records: [SegmentRecord]) {
        self.created = created; self.flags = flags; self.reserved = reserved; self.size = size; self.records = records
    }
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { ptr in UInt32(crc32(0, ptr.bindMemory(to: Bytef.self).baseAddress, uInt(ptr.count))) }
    }
    public static func parse(_ data: Data) throws -> Segment {
        try requireStorage(data.count >= 32 && data.count <= maximumSize, "Invalid segment size.")
        try requireStorage(data.prefix(4) == Data("SEGB".utf8) && data.le32(16) == 10, "Unsupported SEGB version.")
        let count = Int(data.le32(4)), created = Double(bitPattern: data.le64(8))
        try validClock(created)
        try requireStorage(count <= (data.count - 32) / 16, "Footer exceeds capacity.")
        let boundary = data.count - 16 * count
        var previous = 0, records: [SegmentRecord] = []
        for index in 0..<count {
            let pos = data.count - 16 * (index + 1)
            let end = Int(data.le32(pos)), state = data.le32(pos + 4)
            let time = Double(bitPattern: data.le64(pos + 8))
            let aligned = (previous + 3) & ~3
            if state != 1 {
                // Opaque non-active states are retained, not interpreted as usage.
                try requireStorage(end == 0 || (end >= aligned && 32 + end <= boundary), "Invalid opaque record extent.")
                let payload = end > aligned ? data.subdata(in: (32+aligned)..<(32+end)) : Data()
                records.append(SegmentRecord(state: state, timestamp: time, payload: payload))
                if end > 0 { previous = end }
                continue
            }
            try validClock(time)
            try requireStorage(end >= aligned + 8 && 32 + end <= boundary, "Payload overlaps footer.")
            let payload = data.subdata(in: (40+aligned)..<(32+end))
            try requireStorage(checksum(payload) == data.le32(32+aligned), "SEGB CRC mismatch.")
            records.append(SegmentRecord(timestamp: time, flag: data.le32(36+aligned), payload: payload))
            previous = end
        }
        return Segment(created: created, flags: data.le32(20), reserved: data.le64(24), size: data.count, records: records)
    }
    public func encoded() throws -> Data {
        try requireStorage(size >= 32 && size <= Self.maximumSize && records.count <= (size-32)/16, "Segment capacity exceeded.", "segment_capacity")
        let boundary = size - records.count * 16
        var data = Data(count: size), previous = 0
        data.replaceSubrange(0..<4, with: Data("SEGB".utf8))
        data.put32(UInt32(records.count), 4); data.put64(created.bitPattern, 8)
        data.put32(10,16); data.put32(flags,20); data.put64(reserved,24)
        for (index, r) in records.enumerated() {
            let aligned = (previous + 3) & ~3
            let end = r.state != 1 && r.payload.isEmpty ? 0 : aligned + (r.state == 1 ? 8 : 0) + r.payload.count
            try requireStorage(end == 0 || 32 + end <= boundary, "Segment capacity exceeded.", "segment_capacity")
            if end > 0 {
                let start = 32 + aligned + (r.state == 1 ? 8 : 0)
                if r.state == 1 { data.put32(Self.checksum(r.payload),32+aligned); data.put32(r.flag,36+aligned) }
                data.replaceSubrange(start..<(start+r.payload.count), with: r.payload)
                previous = end
            }
            let footer = size - 16 * (index+1)
            data.put32(UInt32(end),footer); data.put32(r.state,footer+4); data.put64(r.timestamp.bitPattern,footer+8)
        }
        _ = try Self.parse(data)
        return data
    }
}
public struct UsageEvent {
    public var opening: Bool
    public var time: Double
    public var bundle: String
    public init(opening: Bool, time: Double, bundle: String) { self.opening = opening; self.time = time; self.bundle = bundle }
}
public enum AppUsageProto {
    static func varint(_ data: Data, _ offset: inout Int) throws -> UInt64 {
        var value: UInt64 = 0
        for shift in stride(from: 0, through: 63, by: 7) {
            try requireStorage(offset < data.count, "Truncated protobuf.")
            let byte = data[offset]; offset += 1
            try requireStorage(shift != 63 || byte <= 1, "Protobuf overflow.")
            value |= UInt64(byte & 127) << shift
            if byte & 128 == 0 { return value }
        }
        throw StorageFailure("unsupported_format", "Protobuf overflow.")
    }
    public static func decode(_ data: Data) throws -> UsageEvent {
        try requireStorage(data.count <= 65536, "AppUsage payload too large.")
        var p = 0, state: UInt64?, time: Double?, bundle: String?
        while p < data.count {
            let key = try varint(data,&p), number = key >> 3, wire = key & 7
            try requireStorage(number > 0 && number <= 536870911, "Invalid protobuf key.")
            switch wire {
            case 0:
                let value = try varint(data,&p)
                if number == 1 { try requireStorage(state == nil && value <= 1, "Invalid event state."); state = value }
            case 1, 5:
                let size = wire == 1 ? 8 : 4
                try requireStorage(data.count-p >= size, "Truncated fixed field.")
                if number == 2 {
                    try requireStorage(wire == 1 && time == nil, "Duplicate or invalid clock.")
                    time = Double(bitPattern: data.le64(p)) - 978307200
                }
                p += size
            case 2:
                let length = try varint(data,&p)
                try requireStorage(length <= UInt64(data.count-p), "Truncated string.")
                if number == 3 {
                    try requireStorage(bundle == nil && length <= 4096, "Invalid bundle field.")
                    bundle = String(data: data.subdata(in: p..<(p+Int(length))),encoding: .utf8)
                }
                p += Int(length)
            default: throw StorageFailure("unsupported_format", "Unsupported protobuf wire type.")
            }
        }
        guard let state, let time, let bundle, !bundle.isEmpty,
              !bundle.unicodeScalars.contains(where: { $0.value < 32 }) else { throw StorageFailure("unsupported_format", "Missing AppUsage fields.") }
        try validClock(time)
        return UsageEvent(opening: state == 1,time: time,bundle: bundle)
    }
    public static func encode(_ event: UsageEvent) throws -> Data {
        try validClock(event.time)
        try requireStorage(SessionRules.isValidBundleID(event.bundle), "Invalid bundle.", "invalid_input")
        var data = Data([8,event.opening ? 1 : 0,17])
        var clock = Data(count:8); clock.put64((event.time+978307200).bitPattern,0); data.append(clock); data.append(26)
        let bytes = Data(event.bundle.utf8)
        var count = UInt64(bytes.count)
        while count >= 128 { data.append(UInt8(count & 127) | 128); count >>= 7 }
        data.append(UInt8(count)); data.append(bytes); data.append(contentsOf:[40,1]); return data
    }
}
public struct StoredSession: Codable, Equatable {
    public var bundle: String
    public var start: Double
    public var end: Double
    public init(bundle: String, start: Double, end: Double) { self.bundle = bundle; self.start = start; self.end = end }
}
public func pairUsage(_ events: [UsageEvent]) throws -> [StoredSession] {
    var open: [String:Double] = [:], result: [StoredSession] = []
    for event in events.enumerated().sorted(by: { $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time }).map(\.element) {
        if event.opening { open[event.bundle] = event.time }
        else if let start = open.removeValue(forKey:event.bundle) {
            try requireStorage(event.time >= start, "End precedes start.")
            result.append(StoredSession(bundle:event.bundle,start:start,end:event.time))
        }
    }
    return result
}
