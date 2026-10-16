import Foundation

/// One usage session for an app, in seconds since the start of the edited day.
public struct UsageSession: Identifiable, Equatable, Codable {
    public var id = UUID()
    public var bundleID: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var duration: TimeInterval { end - start }
    public init(bundleID: String, start: TimeInterval, end: TimeInterval) {
        self.bundleID = bundleID; self.start = start; self.end = end
    }
}

public enum ValidationError: Error, Equatable, CustomStringConvertible {
    case badBundleID(String), outOfDay, tooShort, nonFinite
    public var description: String {
        switch self {
        case .badBundleID(let b): return "Invalid bundle identifier: \(b)"
        case .outOfDay: return "Session must stay inside one day"
        case .tooShort: return "Session must be at least one minute"
        case .nonFinite: return "Session time is not a number"
        }
    }
}

public enum SessionRules {
    public static let day: TimeInterval = 86_400
    public static let minimum: TimeInterval = 60
    public static func isValidBundleID(_ s: String) -> Bool {
        guard s.count >= 3, s.count <= 155, s.contains(".") else { return false }
        return s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" || $0 == "_" || $0 == "_" || $0 == "_" }
            && !s.hasPrefix(".") && !s.hasSuffix(".") && !s.contains("..")
    }
    public static func validate(_ s: UsageSession) throws {
        guard s.start.isFinite, s.end.isFinite else { throw ValidationError.nonFinite }
        guard isValidBundleID(s.bundleID) else { throw ValidationError.badBundleID(s.bundleID) }
        guard s.start >= 0, s.end <= day, s.start < s.end else { throw ValidationError.outOfDay }
        guard s.duration >= minimum else { throw ValidationError.tooShort }
    }
    /// Union of all session intervals. Used for screen-on time, never to forbid overlap.
    public static func mergedIntervals(_ ss: [UsageSession]) -> [ClosedRange<TimeInterval>] {
        var out: [ClosedRange<TimeInterval>] = []
        for s in ss.sorted(by: { $0.start < $1.start }) {
            if let last = out.last, s.start <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, s.end)
            } else { out.append(s.start...s.end) }
        }
        return out
    }
    public static func rawTotal(_ ss: [UsageSession]) -> TimeInterval { ss.reduce(0) { $0 + $1.duration } }
    public static func screenOnTotal(_ ss: [UsageSession]) -> TimeInterval {
        mergedIntervals(ss).reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }
    public static func snap(_ t: TimeInterval, step: TimeInterval = 60) -> TimeInterval {
        min(max((t / step).rounded() * step, 0), day)
    }
}

// MARK: helper wire format (fixed operations only)

public enum HelperOp: String, Codable, CaseIterable { case probe, read, backup, verifyBackup, apply }

public struct HelperReply: Codable, Equatable {
    public var ok: Bool
    public var code: String        // machine readable: ok, not_root, unsupported_schema, no_backup, blocked, bad_request
    public var message: String
    public var details: [String: String]
    public init(ok: Bool, code: String, message: String, details: [String: String] = [:]) {
        self.ok = ok; self.code = code; self.message = message; self.details = details
    }
}

public enum Capability: Equatable {
    case unknown(String)           // helper missing or not runnable
    case readOnly(String)          // helper runs but lacks root or schema
    case ready                     // root, backup verified path, schema supported
    public var canApply: Bool { self == .ready }
    public var summary: String {
        switch self {
        case .unknown(let m): return "Unavailable. \(m)"
        case .readOnly(let m): return "Live access unavailable. \(m)"
        case .ready: return "Ready"
        }
    }
    /// Fail closed: only an explicit, fully ok probe reply with supported schema enables apply.
    public static func from(_ r: HelperReply?) -> Capability {
        guard let r else { return .unknown("Helper did not answer.") }
        guard r.ok, r.code == "ready", r.details["root"] == "1",
              r.details["schema"] == "supported", r.details["protocol"] == "native-v1",
              r.details["authenticated"] == "1", r.details["writer"] == "gemini_ios_full_native" else {
            return .readOnly(r.message)
        }
        return .ready
    }
}
