import Foundation
/// Same Gemini Swift SEGBV2 decoder and per-file pairing as loadLocalData.
/// Bounds and CRC validation runs before the original parser to avoid malformed
/// record offsets. Unaligned loads are the sole portability edit to SEGBV2.
enum GeminiSwiftReader {
 static func sessions(_ paths: [URL]) throws -> [StoredSession] {
  var loaded: [StoredSession] = []
  for path in paths {
   let bytes = try boundedBytes(path)
   _ = try Segment.parse(bytes)
   let (_,records) = try SEGBV2.parse(data:bytes)
   var open: [String:Double] = [:]
   for record in records where record.state == 1 {
    guard let event = SEGBV2.decodeAppUsage(payload:record.payload) else { continue }
    if event.starting { open[event.bundleId] = record.timestamp }
    else if let start = open.removeValue(forKey:event.bundleId) {
     loaded.append(StoredSession(bundle:event.bundleId,start:start,end:max(start,record.timestamp)))
    }
   }
  }
  return loaded.sorted { $0.start < $1.start }
 }
}
