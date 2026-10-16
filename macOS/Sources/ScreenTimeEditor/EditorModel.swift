import SwiftUI
import STCore

@MainActor @Observable
final class EditorModel {
  var date = Calendar.current.startOfDay(for: .now)
  var status: SystemStatus?
  var statusError: String?
  var sessions: [Session] = []
  private var original: [Session] = []
  var revision = ""
  var warnings: [String] = []
  var loading = false
  var loadError: String?
  var permissionDenied = false
  /// From the last successful read; apply needs both this and status.canApply.
  var readCanApply = false
  var readBlockReason: String?
  var applyBlockedReason: String? {
    if let s = status, !s.canApply { return s.reason ?? s.warnings.first ?? "The backend reports that applying edits is not supported on this system. Nothing will be written." }
    if status != nil && !readCanApply && !loading && loadError == nil { return readBlockReason ?? "The backend reports that applying edits is not supported. Nothing will be written." }
    return nil
  }
  var applying = false
  var applyMessage: String?
  var confirmingSourceChanged = false
  var confirmingApply = false
  var confirmingDiscard = false
  private var pendingDate: Date?
  private var loadGeneration = 0
  /// True when the last read failed while unsaved edits were kept; applying is blocked.
  var stale = false
  var locked: Bool { applying }
  var selection: String?
  private var undoStack = UndoStack<[Session]>()
  private(set) var canUndo = false
  private(set) var canRedo = false

  private let backend: Backend?
  var dayStart: Double { DayMath.dayStart(date) }
  var dayEnd: Double { DayMath.dayEnd(date) }
  var range: ClosedRange<Double> { dayStart...dayEnd }
  /// 82800, 86400 or 90000 seconds depending on DST.
  var dayLength: Double { max(3600, dayEnd - dayStart) }
  /// True when the backend reported a Full Disk Access / authorization denial.
  var needsFullDiskAccess: Bool {
    let e = (loadError ?? "").lowercased()
    return e.contains("authorization denied") || e.contains("operation not permitted") || e.contains("not authorized") || e.contains("full disk") || e.contains("permission denied")
  }
  var dirty: Bool { sessions.map(key) != original.map(key) }
  var canApply: Bool {
    dirty && !applying && !loading && loadError == nil && !stale && !revision.isEmpty && status?.canApply == true && readCanApply && backend != nil
  }
  var overlapping: Set<String> { DayMath.overlaps(sessions) }
  // Display filtering only. Hidden records remain in edits, undo and Apply.
  var showShortSessions = false
  var timelineZoom = 1.0
  var shortSessionCount: Int { sessions.filter { $0.duration < 60 }.count }
  var visibleSessions: [Session] { showShortSessions ? sessions : sessions.filter { $0.duration >= 60 } }
  var bundles: [String] { Array(Set(visibleSessions.map(\.bundle))).sorted() }

  private func key(_ s: Session) -> String { "\(s.bundle)|\(s.start)|\(s.end)" }

  init() {
    #if SWIFT_PACKAGE
    let url = Bundle.module.url(forResource: "backend", withExtension: "py")
    #else
    let url: URL? = nil   // only the offscreen test harness builds without SwiftPM; it uses init(scriptURL:)
    #endif
    if let url { backend = Backend(scriptURL: url) } else { backend = nil; loadError = "The bundled backend is missing." }
  }
  /// Uses the real backend script at an explicit path (test harness). No data is substituted.
  init(scriptURL: URL) { backend = Backend(scriptURL: scriptURL) }

  func bootstrap() async {
    await refreshStatus()
    await load()
  }

  func refreshStatus() async {
    guard let backend else { return }
    do { status = try await backend.status(); statusError = nil }
    catch { status = nil; statusError = error.localizedDescription; if (error as? BackendError)?.isPermissionDenied == true { permissionDenied = true } }
  }

  func load() async {
    guard let backend else { return }
    loadGeneration += 1
    let gen = loadGeneration, ds = dayStart, de = dayEnd
    loading = true
    defer { if gen == loadGeneration { loading = false } }
    do {
      let r = try await backend.read(dayStart: ds, dayEnd: de)
      guard gen == loadGeneration else { return }   // a newer load superseded this one
      let day = DayMath.intoDay(r.sessions, start: ds, end: de)
      sessions = day.sessions; original = sessions
      revision = r.revision.trimmingCharacters(in: .whitespacesAndNewlines); warnings = r.warnings
      readCanApply = r.canApply; readBlockReason = r.applyBlockReason
      if day.malformed > 0 { readCanApply = false; readBlockReason = "Some records could not be read, so editing is blocked."; warnings.append("\(day.malformed) malformed session(s) were ignored.") }
      if day.clipped > 0 { warnings.append("\(day.clipped) session(s) cross midnight and are shown clipped to this day.") }
      if revision.isEmpty { loadError = "The backend returned no revision, so edits can't be verified."; permissionDenied = false; sessions = []; original = []; return }
      loadError = nil; permissionDenied = false; stale = false
      selection = nil; undoStack.reset(); sync()
    } catch {
      guard gen == loadGeneration else { return }
      loadError = error.localizedDescription
      permissionDenied = (error as? BackendError)?.isPermissionDenied == true
      readCanApply = false
      if dirty { stale = true }   // keep the draft, but never apply it against an unknown state
      else { sessions = []; original = []; revision = "" }
    }
  }

  func shiftDay(_ d: Int) { requestDay(Calendar.current.date(byAdding: .day, value: d, to: date) ?? date) }
  func goToday() { requestDay(.now) }
  /// Asks for confirmation first when there are unapplied edits.
  func requestDay(_ d: Date) {
    guard !locked else { return }
    if dirty { pendingDate = d; confirmingDiscard = true } else { setDate(d) }
  }
  func confirmPendingDay() { if let d = pendingDate { pendingDate = nil; setDate(d) } }
  func cancelPendingDay() { pendingDate = nil }
  private func setDate(_ d: Date) {
    date = Calendar.current.startOfDay(for: d); applyMessage = nil
    sessions = []; original = []; revision = ""; stale = false
    Task { await load() }
  }
  func reload() { guard !locked else { return }; if dirty { pendingDate = date; confirmingDiscard = true } else { Task { await load() } } }

  private func sync() { canUndo = undoStack.canUndo; canRedo = undoStack.canRedo }
  /// Call once before a series of mutations (e.g. at drag start).
  func checkpoint() { undoStack.record(sessions); sync() }
  func undo() { if !locked,  let p = undoStack.undo(current: sessions) { sessions = p; sync() } }
  func redo() { if !locked,  let n = undoStack.redo(current: sessions) { sessions = n; sync() } }

  func update(_ s: Session) {
    guard !locked, s.isValid else { return }
    guard let i = sessions.firstIndex(where: { $0.id == s.id }) else { return }
    sessions[i] = DayMath.clamp(s, to: range)
  }
  func commitEdit(_ s: Session) { guard !locked, s.isValid else { return }; checkpoint(); update(s) }
  func add(bundle: String, start: Double, end: Double) {
    guard !locked, start.isFinite, end.isFinite, end > start else { return }
    checkpoint()
    let s = DayMath.clamp(Session(bundle: bundle, start: start, end: end), to: range)
    sessions.append(s); sessions.sort { $0.start < $1.start }; selection = s.id
  }
  func delete(_ id: String) {
    guard !locked else { return }
    checkpoint(); sessions.removeAll { $0.id == id }
    if selection == id { selection = nil }
  }
  func slice(_ id: String, at t: Double) {
    guard !locked, t.isFinite, let i = sessions.firstIndex(where: { $0.id == id }), let (a, b) = DayMath.slice(sessions[i], at: t) else { return }
    checkpoint(); sessions[i] = a; sessions.insert(b, at: i + 1)
  }
  func discard() { guard !locked else { return }; checkpoint(); sessions = original }

  func cancelSourceOverride() { confirmingSourceChanged = false }
  func reloadChangedSource() async {
    confirmingSourceChanged = false
    applyMessage = nil
    await load()
  }
  func overrideChangedSource() async {
    confirmingSourceChanged = false
    await apply(overrideSourceChanges: true)
  }

  func apply(overrideSourceChanges: Bool = false) async {
    guard let backend, canApply, !locked else { return }
    applying = true; defer { applying = false }
    let req = ApplyRequest(dayStart: dayStart, dayEnd: dayEnd,
      sessions: sessions.map { ApplySession(id: $0.id, bundle: $0.bundle, start: $0.start, end: $0.end) }, revision: revision, overrideSourceChanges: overrideSourceChanges)
    do {
      let r = try await backend.apply(req)
      guard let backup = r.backupLocation else {
        applyMessage = "The backend did not report a backup, so this change is not confirmed. Reload before trying again."
        stale = true; return
      }
      let raw = (r.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
      let needsLogout = r.logoutRequired ?? true
      let st = raw.uppercased().hasPrefix("SUCCESS") ? "applied" : (raw.isEmpty ? "none reported" : raw)
      let resetBackup = r.resetBackupPath.map { " Reset backup saved at \($0)." } ?? ""
      applyMessage = "Backup saved at \(backup)." + resetBackup + " Status: \(st)." + (needsLogout ? " Log out and back in, or restart, for Screen Time to show the change." : " Local reset completed.")
      await load()
    } catch {
      if (error as? BackendError)?.code == "stale_revision" {
        confirmingSourceChanged = true
        applyMessage = nil
      } else {
        applyMessage = "Not applied: \(error.localizedDescription)"
      }
    }
  }
}
