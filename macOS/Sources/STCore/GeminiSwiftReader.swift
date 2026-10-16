import Foundation
import CryptoKit

/// Restored 051831 ScreenTimeStore.loadLocalData pairing, with no demo fallback.
/// The original SEGBV2 codec is retained, preceded by strict bounds/CRC checks.
public enum GeminiSwiftReader {
  public static func sessions(paths: [URL]) throws -> [Session] {
    var result: [Session] = []
    for path in paths.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
            let size = attributes[.size] as? NSNumber, size.intValue <= 64 * 1024 * 1024 else {
        throw BackendError(message: "Unsafe or oversized AppUsage segment.")
      }
      let bytes = try Data(contentsOf: path)
      try validate(bytes)
      let (_, records) = try SEGBV2.parse(data: bytes)
      var opened: [String: (Double, Int)] = [:]
      for (index, record) in records.enumerated() where record.state == 1 {
        guard let event = SEGBV2.decodeAppUsage(payload: record.payload) else { continue }
        if event.starting { opened[event.bundleId] = (record.timestamp, index) }
        else if let start = opened.removeValue(forKey: event.bundleId) {
          let identity = path.lastPathComponent + ":" + String(start.1) + "|" + String(index)
          let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
          result.append(Session(id: id, bundle: event.bundleId, start: start.0, end: max(start.0, record.timestamp)))
        }
      }
    }
    return result.sorted { $0.start < $1.start }
  }

  static func validate(_ data: Data) throws {
    func fail() throws -> Never { throw BackendError(message: "Invalid AppUsage segment.") }
    guard data.count >= 32, data.count <= 64 * 1024 * 1024, data.prefix(4) == Data([83,69,71,66]) else { try fail() }
    func u32(_ offset: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }.littleEndian }
    let count = Int(u32(4))
    guard u32(16) == 10, count <= (data.count - 32) / 16 else { try fail() }
    let boundary = data.count - count * 16
    var previous = 0
    for index in 0..<count {
      let position = data.count - (index + 1) * 16
      let end = Int(u32(position)), state = u32(position + 4)
      let timestamp = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: position + 8, as: Double.self) }
      guard timestamp.isFinite else { try fail() }
      let aligned = (previous + 3) & ~3
      if state == 1 {
        guard end >= aligned + 8, 32 + end <= boundary else { try fail() }
        let payload = data.subdata(in: (40 + aligned)..<(32 + end))
        guard SEGBV2.crc32Checksum(payload) == u32(32 + aligned) else { try fail() }
      } else if end != 0 {
        guard end >= aligned, 32 + end <= boundary else { try fail() }
      }
      if end != 0 { previous = end }
    }
  }
}
