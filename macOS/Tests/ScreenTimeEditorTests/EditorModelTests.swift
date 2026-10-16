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
        if os.path.exists(r"\(dir.path)/changed") and not req.get("overrideSourceChanges",False):
            print(json.dumps({"error":"Screen Time data changed since you loaded it.","code":"stale_revision"})); sys.exit(0)
        if os.path.exists(r"\(dir.path)/backup-fail"):
            print(json.dumps({"error":"Fresh backup failed","code":"backup_failed"})); sys.exit(0)
        open(r"\(dir.path)/request.json","w").write(json.dumps(req))
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
  func testSuccessfulSIPOffResetDoesNotAskForLogout() async throws {
    let url = try script()
    var source = try String(contentsOf: url, encoding: .utf8)
    source = source.replacingOccurrences(of: "\"logoutRequired\":True", with: "\"logoutRequired\":False")
    source = source.replacingOccurrences(of: "\"status\":\"SUCCESS_LOGOUT_REQUIRED\"", with: "\"status\":\"SUCCESS_RESET_COMPLETED\",\"resetBackupPath\":\"/tmp/fixture-reset-backup\"")
    try source.write(to: url, atomically: true, encoding: .utf8)
    let m = EditorModel(scriptURL: url)
    await m.bootstrap()
    var s = m.sessions[0]; s.end += 600; m.commitEdit(s)
    await m.apply()
    XCTAssertTrue(m.applyMessage?.contains("fixture-backup") == true)
    XCTAssertFalse(m.applyMessage?.contains("Log out") == true)
    XCTAssertFalse(m.applyMessage?.contains("restart") == true)
    XCTAssertTrue(m.applyMessage?.contains("fixture-reset-backup") == true)
    XCTAssertTrue(m.applyMessage?.contains("Local reset completed") == true)
  }

  func testMissingResetResultDefaultsToLogoutGuidance() async throws {
    let url = try script()
    var source = try String(contentsOf: url, encoding: .utf8)
    source = source.replacingOccurrences(of: ",\"logoutRequired\":True", with: "")
    try source.write(to: url, atomically: true, encoding: .utf8)
    let m = EditorModel(scriptURL: url)
    await m.bootstrap()
    var s = m.sessions[0]; s.end += 600; m.commitEdit(s)
    await m.apply()
    XCTAssertTrue(m.applyMessage?.contains("Log out") == true)
  }

  func staleModel() async throws -> EditorModel {
    let m = try await model()
    var s = m.sessions[0]; s.end += 600; m.commitEdit(s)
    try Data().write(to: dir.appendingPathComponent("changed"))
    await m.apply()
    XCTAssertTrue(m.confirmingSourceChanged)
    XCTAssertTrue(m.dirty)
    XCTAssertNil(m.applyMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("apply.log").path))
    return m
  }
  func testSourceChangedCancelKeepsDraftWithoutApply() async throws {
    let m = try await staleModel()
    let draft = m.sessions[0].end
    m.cancelSourceOverride()
    XCTAssertFalse(m.confirmingSourceChanged)
    XCTAssertEqual(m.sessions[0].end,draft)
    XCTAssertTrue(m.dirty)
  }
  func testSourceChangedReloadReplacesDraftWithoutApply() async throws {
    let m = try await staleModel()
    await m.reloadChangedSource()
    XCTAssertFalse(m.confirmingSourceChanged)
    XCTAssertFalse(m.dirty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("apply.log").path))
  }
  func testSourceChangedOverrideSendsExplicitConsent() async throws {
    let m = try await staleModel()
    await m.overrideChangedSource()
    let data = try Data(contentsOf: dir.appendingPathComponent("request.json"))
    let req = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
    XCTAssertEqual(req["overrideSourceChanges"] as? Bool,true)
    XCTAssertFalse(m.confirmingSourceChanged)
    XCTAssertTrue(m.applyMessage?.contains("fixture-backup") == true)
  }
  func testOverrideBackupFailureKeepsDraftAndReportsError() async throws {
    let m = try await staleModel()
    try Data().write(to: dir.appendingPathComponent("backup-fail"))
    await m.overrideChangedSource()
    XCTAssertTrue(m.dirty)
    XCTAssertFalse(m.confirmingSourceChanged)
    XCTAssertTrue(m.applyMessage?.contains("Fresh backup failed") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("apply.log").path))
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
  func testShortFilterIsPresentationOnlyAndToggleRestoresAll() async throws {
    let m = try await model()
    let tiny = Session(id: "tiny", bundle: "com.short", start: m.dayStart + 20, end: m.dayStart + 20.2)
    let minute = Session(id: "minute", bundle: "com.minute", start: m.dayStart + 30, end: m.dayStart + 90)
    m.sessions += [tiny, minute]
    let all = m.sessions
    XCTAssertEqual(m.shortSessionCount, 1)
    XCTAssertFalse(m.visibleSessions.contains(tiny))
    XCTAssertTrue(m.visibleSessions.contains(minute))
    XCTAssertFalse(m.bundles.contains("com.short"))
    m.showShortSessions = true
    XCTAssertEqual(m.visibleSessions, all)
    XCTAssertTrue(m.bundles.contains("com.short"))
    m.showShortSessions = false
    XCTAssertEqual(m.sessions, all)
  }

  func testFilteredRecordsStillGoToApply() async throws {
    let m = try await model()
    let tiny = Session(id: "tiny", bundle: "com.short", start: m.dayStart + 20, end: m.dayStart + 20.2)
    m.sessions.append(tiny)
    XCTAssertFalse(m.visibleSessions.contains(tiny))
    await m.apply()
    let data = try Data(contentsOf: dir.appendingPathComponent("request.json"))
    let req = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String:Any])
    let sessions = try XCTUnwrap(req["sessions"] as? [[String:Any]])
    XCTAssertTrue(sessions.contains { $0["id"] as? String == "tiny" })
  }

  func testFilterDoesNotMakeCleanDataDirty() async throws {
    let m = try await model()
    m.showShortSessions = true
    m.timelineZoom = 4
    XCTAssertFalse(m.dirty)
    XCTAssertFalse(m.canApply)
  }

  func testApplyPermissionsShowHelpAndKeepDraft() async throws {
    for code in ["permission_denied", "system_store_permission_denied"] {
      let url = try script()
      var source = try String(contentsOf: url, encoding: .utf8)
      source = source.replacingOccurrences(of: "Fresh backup failed", with: "Access denied")
      source = source.replacingOccurrences(of: "backup_failed", with: code)
      try source.write(to: url, atomically: true, encoding: .utf8)
      try Data().write(to: dir.appendingPathComponent("backup-fail"))
      let m = EditorModel(scriptURL: url)
      await m.bootstrap()
      var s = m.sessions[0]; s.end += 600; m.commitEdit(s)
      let draft = m.sessions
      await m.apply()
      XCTAssertTrue(m.showingApplyPermissionHelp)
      XCTAssertEqual(m.applyNeedsSystemPrivileges, code == "system_store_permission_denied")
      XCTAssertEqual(m.sessions, draft)
      XCTAssertTrue(m.dirty)
      XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("apply.log").path))
      try FileManager.default.removeItem(at: dir.appendingPathComponent("backup-fail"))
    }
  }

  func testSafariFragmentsRemainVisibleWhenDailyTotalExceedsMinute() async throws {
    let m = try await model()
    let fragments = [28.607, 30.664, 10.825, 59.753].enumerated().map { index, duration in
      Session(id: "safari-\(index)", bundle: "com.apple.Safari",
        start: m.dayStart + Double(index) * 100,
        end: m.dayStart + Double(index) * 100 + duration)
    }
    m.sessions = fragments
    XCTAssertFalse(m.showShortSessions)
    XCTAssertEqual(m.visibleSessions, fragments)
    XCTAssertEqual(m.shortSessionCount, 0)
    XCTAssertTrue(m.bundles.contains("com.apple.Safari"))
  }

}
