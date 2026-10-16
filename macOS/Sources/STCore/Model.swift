import Foundation

/// Cocoa epoch seconds (since 2001-01-01 UTC), matching the backend contract.
public struct Session: Identifiable, Hashable, Codable, Sendable {
  public var id: String
  public var bundle: String
  public var start: Double
  public var end: Double
  public init(id: String = UUID().uuidString, bundle: String, start: Double, end: Double) {
    self.id = id; self.bundle = bundle; self.start = start; self.end = end
  }
  public var duration: Double { max(0, end - start) }
  /// Finite, ordered times and a nonempty bundle.
  public var isValid: Bool { start.isFinite && end.isFinite && end > start && !bundle.trimmingCharacters(in: .whitespaces).isEmpty }
}

public struct SystemStatus: Codable, Sendable, Equatable {
  public var macOS: String
  public var build: String
  public var sip: String
  public var sipDetails: String?
  public var warnings: [String]
  /// Whether the backend can safely write. Missing means false, never assumed true.
  public var canApply: Bool
  public var reason: String?
  public var applyBlockReason: String?
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: K.self)
    macOS = try c.decode(String.self, forKey: .macOS); build = try c.decode(String.self, forKey: .build)
    sip = try c.decode(String.self, forKey: .sip); sipDetails = try c.decodeIfPresent(String.self, forKey: .sipDetails)
    warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    canApply = try c.decodeIfPresent(Bool.self, forKey: .canApply) ?? false
    applyBlockReason = try c.decodeIfPresent(String.self, forKey: .applyBlockReason)
    reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? applyBlockReason ?? c.decodeIfPresent(String.self, forKey: .error)
  }
  enum K: String, CodingKey { case macOS, build, sip, sipDetails, warnings, canApply, reason, error, applyBlockReason }
}

public struct ReadResult: Codable, Sendable {
  public var sessions: [Session]
  public var revision: String
  public var warnings: [String]
  public var canApply: Bool
  public var applyBlockReason: String?
  public init(from d: Decoder) throws {
    let c = try d.container(keyedBy: K.self)
    applyBlockReason = try c.decodeIfPresent(String.self, forKey: .applyBlockReason)
    sessions = try c.decode([Session].self, forKey: .sessions)
    revision = try c.decode(String.self, forKey: .revision)
    warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    canApply = try c.decodeIfPresent(Bool.self, forKey: .canApply) ?? false
  }
  enum K: String, CodingKey { case sessions, revision, warnings, canApply, applyBlockReason }
}

public struct ApplySession: Codable, Sendable, Equatable { public var id: String; public var bundle: String; public var start: Double; public var end: Double
  public init(id: String, bundle: String, start: Double, end: Double) { self.id = id; self.bundle = bundle; self.start = start; self.end = end } }
public struct ApplyRequest: Codable, Sendable {
  public var dayStart: Double, dayEnd: Double
  public var sessions: [ApplySession]
  public var revision: String
  public init(dayStart: Double, dayEnd: Double, sessions: [ApplySession], revision: String) {
    self.dayStart = dayStart; self.dayEnd = dayEnd; self.sessions = sessions; self.revision = revision }
}
public struct ApplyResult: Codable, Sendable {
  public var backup: String?
  public var backupPath: String?
  public var logoutRequired: Bool?
  public var path: String?
  public var status: String?
  public var backupLocation: String? { [backup, backupPath].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } }
}

public enum DayMath {
  public static let day: Double = 86_400
  /// Local midnight for the given date, as Cocoa seconds.
  public static func dayStart(_ date: Date, calendar: Calendar = .current) -> Double {
    calendar.startOfDay(for: date).timeIntervalSinceReferenceDate
  }
  public static func dayEnd(_ date: Date, calendar: Calendar = .current) -> Double {
    let s = calendar.startOfDay(for: date)
    return (calendar.date(byAdding: .day, value: 1, to: s) ?? s.addingTimeInterval(day)).timeIntervalSinceReferenceDate
  }
  /// Length of the local day in seconds (82800, 86400 or 90000 across DST).
  public static func length(_ start: Double, _ end: Double) -> Double { max(1, end - start) }
  /// Keeps sessions overlapping [start,end), clipping cross-midnight ones to the day. Drops invalid or empty ones.
  /// Returns the kept sessions and how many were dropped as malformed / clipped.
  public static func intoDay(_ all: [Session], start: Double, end: Double) -> (sessions: [Session], malformed: Int, clipped: Int) {
    var out: [Session] = [], bad = 0, clipped = 0
    for s in all {
      guard s.isValid else { bad += 1; continue }
      guard s.end > start, s.start < end else { continue }
      var c = s
      if s.start < start || s.end > end { c.start = max(s.start, start); c.end = min(s.end, end); clipped += 1 }
      if c.end > c.start { out.append(c) }
    }
    return (out.sorted { $0.start < $1.start }, bad, clipped)
  }
  public static func snap(_ t: Double, step: Double = 60) -> Double { t.isFinite ? (t / step).rounded() * step : 0 }
  public static func clamp(_ s: Session, to range: ClosedRange<Double>, minLength: Double = 60) -> Session {
    var r = s
    r.start = min(max(r.start, range.lowerBound), range.upperBound - minLength)
    r.end = min(max(r.end, r.start + minLength), range.upperBound)
    return r
  }
  /// Splits a session at time t; returns nil if t is not strictly inside with both halves >= minLength.
  public static func slice(_ s: Session, at t: Double, minLength: Double = 60) -> (Session, Session)? {
    guard t - s.start >= minLength, s.end - t >= minLength else { return nil }
    var a = s; a.end = t
    var b = s; b.id = UUID().uuidString; b.start = t
    return (a, b)
  }
  public static func overlaps(_ s: [Session]) -> Set<String> {
    let sorted = s.sorted { $0.start < $1.start }
    var out = Set<String>()
    for i in sorted.indices { for j in (i+1)..<max(i+1, sorted.count) where sorted[j].start < sorted[i].end {
      out.insert(sorted[i].id); out.insert(sorted[j].id) } }
    return out
  }
  public static func format(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "–" }
    let m = Int((seconds / 60).rounded())
    return m >= 60 ? "\(m/60)h \(m%60)m" : "\(m)m"
  }
}

public struct UndoStack<T> {
  private var past: [T] = [], future: [T] = []
  public init() {}
  public var canUndo: Bool { !past.isEmpty }
  public var canRedo: Bool { !future.isEmpty }
  public mutating func record(_ v: T) { past.append(v); future.removeAll() }
  public mutating func undo(current: T) -> T? { guard let p = past.popLast() else { return nil }; future.append(current); return p }
  public mutating func redo(current: T) -> T? { guard let f = future.popLast() else { return nil }; past.append(current); return f }
  public mutating func reset() { past.removeAll(); future.removeAll() }
}
