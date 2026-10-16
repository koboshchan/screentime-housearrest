import XCTest
import Foundation
import STCore
@testable import ScreenTimeEditor

/// Drives the real EditorModel + Backend against throwaway python scripts. Fixture data only; no live stores, no real apply.
@MainActor
final class EditorModelTests: XCTestCase {
  var dir: URL!
  override func setUpWithError() throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("stm-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

  /// mode: ok | fail | denied
  func script(read: String = "ok", canApply: Bool = true, log: Bool = false) throws -> URL {
    let url = dir.appendingPathComponent("b.py")
    let logPath = dir.appendingPathComponent("apply.log").path
    let py = """
    import sys, json, os
    req = json.load(sys.stdin); c = req["command"]
    if c == "status":
        print(json.dumps({"macOS":"26.0","build":"X","sip":"enabled","canApply":\(canApply ? "True" : "False")}))
    elif c == "read":
        if os.path.exists(r"\(dir.path)/fail"):
            print(json.dumps({"error":"Operation not permitted","code":"permission_denied"})); sys.exit(0)
        s = req["dayStart"]
        print(json.dumps({"sessions":[{"id":"a","bundle":"com.x.a","start":s+3600,"end":s+7200},{"id":"b","bundle":"com.x.b","start":s+10800,"end":s+14400}],"revision":"r1","canApply":\(canApply ? "True" : "False")}))
    elif c == "apply":
        open(r"\(logPath)","a").write("x")
        print(json.dumps({"backupPath":"/tmp/fixture-backup","status":"SUCCESS_LOGOUT_REQUIRED","logoutRequired":True}))
    """
    try py.write(to: url, atomically: true, encoding: .utf8)
    return url
  }
  func model(canApply: Bool = true) async throws -> EditorModel {
    let m = EditorModel(scriptURL: try script(canApply: canApply))
    await m.bootstrap()
    return m
  }

  func testLoadsFixtureSessions() async throws {
    let m = try await model()
    XCTAssertNil(m.loadError); XCTAssertEqual(m.sessions.count, 2); XCTAssertEqual(m.revision, "r1")
    XCTAssertFalse(m.dirty); XCTAssertFalse(m.canApply)
  }
  func testSelectDayReloads() async throws {
    let m = try await model()
    let before = m.date
    m.shiftDay(-1)
    XCTAssertNotEqual(m.date, before)
    try await Task.sleep(nanoseconds: 800_000_000)
    XCTAssertEqual(m.sessions.count, 2); XCTAssertFalse(m.loading)
  }
  func testEditMakesDirtyAndApplyEnabled() async throws {
    let m = try await model()
    var s = m.sessions[0]; s.end += 600
    m.commitEdit(s)
    XCTAssertTrue(m.dirty); XCTAssertTrue(m.canApply)
  }
  func testUndoRestoresClean() async throws {
    let m = try await model()
    var s = m.sessions[0]; s.end += 600
    m.commitEdit(s); m.undo()
    XCTAssertFalse(m.dirty); XCTAssertFalse(m.canApply)
    m.redo(); XCTAssertTrue(m.dirty)
  }
  func testDiscardRestoresOriginal() async throws {
    let m = try await model()
    m.delete(m.sessions[0].id)
    XCTAssertEqual(m.sessions.count, 1); XCTAssertTrue(m.dirty)
    m.discard()
    XCTAssertEqual(m.sessions.count, 2); XCTAssertFalse(m.dirty)
  }
  func testDirtyDayChangeAsksConfirmation() async throws {
    let m = try await model()
    m.delete(m.sessions[0].id)
    let d = m.date
    m.shiftDay(1)
    XCTAssertTrue(m.confirmingDiscard); XCTAssertEqual(m.date, d)
    m.cancelPendingDay(); XCTAssertEqual(m.date, d)
  }
  func testFailedReloadWithDraftIsStaleAndBlocksApply() async throws {
    let m = try await model()
    var s = m.sessions[0]; s.end += 600; m.commitEdit(s)
    XCTAssertTrue(m.canApply)
    FileManager.default.createFile(atPath: dir.appendingPathComponent("fail").path, contents: Data())
    await m.load()
    XCTAssertTrue(m.stale); XCTAssertNotNil(m.loadError); XCTAssertTrue(m.permissionDenied)
    XCTAssertTrue(m.dirty); XCTAssertFalse(m.canApply)
  }
  func testReadDenialWhenCleanClearsSessions() async throws {
    let m = EditorModel(scriptURL: try script())
    FileManager.default.createFile(atPath: dir.appendingPathComponent("fail").path, contents: Data())
    await m.bootstrap()
    XCTAssertTrue(m.sessions.isEmpty); XCTAssertTrue(m.needsFullDiskAccess); XCTAssertFalse(m.canApply)
  }
  func testApplyGatedWhenBackendCannotApply() async throws {
    let m = try await model(canApply: false)
    var s = m.sessions[0]; s.end += 600; m.commitEdit(s)
    XCTAssertTrue(m.dirty); XCTAssertFalse(m.canApply); XCTAssertNotNil(m.applyBlockedReason)
    await m.apply()
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("apply.log").path))
  }
  func testApplyOnlyHitsFixtureScript() async throws {
    let m = try await model()
    var s = m.sessions[0]; s.end += 600; m.commitEdit(s)
    await m.apply()
    XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("apply.log").path))
    XCTAssertTrue(m.applyMessage?.contains("/tmp/fixture-backup") == true); XCTAssertTrue(m.applyMessage?.contains("Log out") == true); XCTAssertFalse(m.applyMessage?.contains("SUCCESS_LOGOUT") == true)
  }
  func testReadCheckReportPrivateAndSanitized() async throws {
    let m = try await model()
    let url = dir.appendingPathComponent("logs/read-check.json")
    try ReadCheck.write(m, to: url)
    let a = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual((a[.posixPermissions] as? Int) ?? 0, 0o600)
    let d = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)
    XCTAssertEqual((d[.posixPermissions] as? Int) ?? 0, 0o700)
    let text = try String(contentsOf: url, encoding: .utf8)
    XCTAssertFalse(text.contains("com.x.a")); XCTAssertTrue(text.contains("\"sessionCount\" : 2"))
  }
  func testReadCheckFreshMissingReportAndSymlinkSafety() async throws {
    let m = try await model()
    let url = dir.appendingPathComponent("fresh/Logs/read-check.json")
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    try ReadCheck.write(m, to: url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    // overwrite existing
    try ReadCheck.write(m, to: url)
    // symlink at report path is replaced, target untouched
    let target = dir.appendingPathComponent("victim.txt"); try "keep".write(to: target, atomically: true, encoding: .utf8)
    let link = dir.appendingPathComponent("fresh/Logs/link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    XCTAssertThrowsError(try ReadCheck.write(m, to: link))
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "keep")
  }
}
