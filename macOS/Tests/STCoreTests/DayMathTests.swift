import Testing
import Foundation
@testable import STCore

@Test func sliceSplitsAndRejectsEdges() {
  let s = Session(id: "a", bundle: "x", start: 0, end: 600)
  let r = DayMath.slice(s, at: 300)!
  #expect(r.0.end == 300 && r.1.start == 300 && r.0.id != r.1.id)
  #expect(DayMath.slice(s, at: 30) == nil)
}
@Test func clampKeepsInsideDay() {
  let s = DayMath.clamp(Session(id: "a", bundle: "x", start: -50, end: 5000), to: 0...3600)
  #expect(s.start == 0 && s.end == 3600)
}
@Test func overlapDetected() {
  let o = DayMath.overlaps([Session(id: "a", bundle: "x", start: 0, end: 100), Session(id: "b", bundle: "y", start: 50, end: 200), Session(id: "c", bundle: "z", start: 300, end: 400)])
  #expect(o == ["a", "b"])
}
@Test func undoRedo() {
  var u = UndoStack<Int>(); u.record(1)
  #expect(u.undo(current: 2) == 1); #expect(u.redo(current: 1) == 2)
}
@Test func snap() { #expect(DayMath.snap(89) == 60) }
@Test func applyRequestEncodes() throws {
  let d = try JSONEncoder().encode(ApplyRequest(dayStart: 0, dayEnd: 1, sessions: [], revision: "r"))
  #expect(String(decoding: d, as: UTF8.self).contains("revision"))
}

@Test func nonFiniteGuards() {
  #expect(DayMath.format(.nan) == "–" && DayMath.format(.infinity) == "–")
  #expect(!Session(bundle: "x", start: .nan, end: 5).isValid)
  #expect(!Session(bundle: " ", start: 0, end: 5).isValid)
  #expect(DayMath.snap(.infinity) == 0)
}
@Test func backendErrorOnExitZero() async throws {
  let dir = FileManager.default.temporaryDirectory
  let url = dir.appendingPathComponent("be-\(UUID().uuidString).py")
  try "import sys,json\nprint(json.dumps({'error':'boom'}))\n".write(to: url, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: url) }
  await #expect(throws: BackendError.self) { _ = try await Backend(scriptURL: url).status() }
}

@Test func dstDayLengths() {
  var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Vancouver")!
  let spring = cal.date(from: DateComponents(year: 2026, month: 3, day: 8))!
  #expect(DayMath.dayEnd(spring, calendar: cal) - DayMath.dayStart(spring, calendar: cal) == 82800)
  var uk = Calendar(identifier: .gregorian); uk.timeZone = TimeZone(identifier: "Europe/London")!
  let fall = uk.date(from: DateComponents(year: 2026, month: 10, day: 25))!
  #expect(DayMath.dayEnd(fall, calendar: uk) - DayMath.dayStart(fall, calendar: uk) == 90000)
}

@Test func intoDayClipsAndFilters() {
  let a = Session(id: "a", bundle: "x", start: -100, end: 100)
  let b = Session(id: "b", bundle: "x", start: 500, end: 2000)
  let c = Session(id: "c", bundle: "x", start: 5000, end: 6000)
  let d = Session(id: "d", bundle: "x", start: .nan, end: 10)
  let r = DayMath.intoDay([b, a, c, d], start: 0, end: 1000)
  #expect(r.sessions.map(\.id) == ["a", "b"] && r.sessions[0].start == 0 && r.sessions[1].end == 1000)
  #expect(r.malformed == 1 && r.clipped == 2)
}
@Test func statusDecodesCanApplyAndDefaultsFalse() throws {
  let j1 = #"{"macOS":"1","build":"b","sip":"enabled","canApply":false,"warnings":[]}"#.data(using: .utf8)!
  #expect(try JSONDecoder().decode(SystemStatus.self, from: j1).canApply == false)
  let j2 = #"{"macOS":"1","build":"b","sip":"enabled"}"#.data(using: .utf8)!
  #expect(try JSONDecoder().decode(SystemStatus.self, from: j2).canApply == false)
}
@Test func backendSendsCommandInBody() async throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("be-\(UUID().uuidString).py")
  try "import sys,json\nr=json.load(sys.stdin)\nprint(json.dumps({'error':'cmd='+r['command']}))\n".write(to: url, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: url) }
  do { _ = try await Backend(scriptURL: url).status(); Issue.record("expected error") }
  catch let e as BackendError { #expect(e.message == "cmd=status") }
}
@Test func permissionErrorDetected() {
  #expect(BackendError(message: "Cannot read local Screen Time stores: [Errno 1] Operation not permitted: 'x'").isPermissionDenied)
  #expect(!BackendError(message: "boom").isPermissionDenied)
  #expect(BackendError(message: "Denied", code: "permission_denied").isPermissionDenied)
  #expect(!BackendError(message: "unable to open database file", code: "read_failed").isPermissionDenied)
  #expect(!BackendError(message: "unable to open database file").isPermissionDenied)
}

@Test func applyBodyHasIdsAndCommand() async throws {
  let url = FileManager.default.temporaryDirectory.appendingPathComponent("be-\(UUID().uuidString).py")
  try "import sys,json\nr=json.load(sys.stdin)\nprint(json.dumps({'error':'ids='+','.join(s['id'] for s in r['sessions'])+' cmd='+r['command']}))\n".write(to: url, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: url) }
  let req = ApplyRequest(dayStart: 0, dayEnd: 10, sessions: [ApplySession(id: "s1", bundle: "b", start: 1, end: 2)], revision: "r")
  do { _ = try await Backend(scriptURL: url).apply(req); Issue.record("expected error") }
  catch let e as BackendError { #expect(e.message == "ids=s1 cmd=apply") }
}
/// Integration: real bundled backend.py through the real Swift Backend. Read-only, never applies.
@Test func realBackendStatusAndNativeRead() async throws {
  let path = FileManager.default.currentDirectoryPath + "/Sources/ScreenTimeEditor/Resources/backend.py"
  let b = Backend(scriptURL: URL(fileURLWithPath: path))
  let s = try await b.status()
  #expect(!s.macOS.isEmpty && s.canApply == false)
  do {
    let r = try await b.read(dayStart: 0, dayEnd: 86400)
    #expect(!r.revision.isEmpty && r.canApply == false)   // readable here
  } catch let e as BackendError {
    // Without Full Disk Access: a real permission error from the stores, not an IPC/JSON error.
    #expect(e.isPermissionDenied, "unexpected backend error: \(e.message)")
    #expect(e.code == "permission_denied", "unexpected code: \(e.code ?? "nil")")
  }
}

@Test func sliceProducesUniqueIds() {
  let s = Session(id: "a", bundle: "x", start: 0, end: 600)
  let r = DayMath.slice(s, at: 300)!
  #expect(r.0.id != r.1.id)
}
