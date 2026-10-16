import Foundation
import Testing
@testable import STCore

@Test func geminiReaderUsesFooterOrderAndResetsPerSegment() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  func write(_ name: String, _ events: [(Double, Bool)]) throws -> URL {
    let records = events.map { SEGBRecord(timestamp: $0.0, payload: SEGBV2.encodeAppUsage(cocoaTs: 999, starting: $0.1, bundleId: "com.apple.Safari")) }
    let data = SEGBV2.build(header: SEGBHeader(count: UInt32(records.count), creationTimestamp: 0, totalSize: 4096), records: records)
    let url = directory.appendingPathComponent(name)
    try data.write(to: url)
    return url
  }
  let first = try write("001", [(10,true),(20,true),(30,false),(40,true)])
  let second = try write("002", [(50,false),(70,true),(60,false)])
  let sessions = try GeminiSwiftReader.sessions(paths: [second,first])
  #expect(sessions.count == 2)
  #expect(sessions[0].bundle == "com.apple.Safari")
  #expect(sessions[0].start == 20 && sessions[0].end == 30)
  #expect(sessions[1].start == 70 && sessions[1].end == 70)
}

@Test func geminiReaderRejectsCorruptSegmentAndNeverInventsFallback() throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  #expect(try GeminiSwiftReader.sessions(paths: []).isEmpty)
  let url = directory.appendingPathComponent("bad")
  try Data([1,2,3]).write(to: url)
  #expect(throws: (any Error).self) { try GeminiSwiftReader.sessions(paths: [url]) }
}
