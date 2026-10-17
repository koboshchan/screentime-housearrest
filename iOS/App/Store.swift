import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [UsageSession] = []
    @Published var capability: Capability = .unknown("Checking.")
    @Published var error: String?
    @Published var selected: UUID?
    @Published var status: String?
    @Published var warnings: [String] = []
    @Published var busy = false
    @Published var loaded = false
    @Published var showStale = false
    @Published var showLossyConfirmation = false
    private var pendingSourceOverride = false
    var uneditableCount: Int { sessions.filter { (try? SessionRules.validate($0)) == nil }.count }
    var lossyMessage: String {
        "\(uneditableCount) session(s) cannot be represented by this editor and will be omitted when today is rewritten. Their recorded usage will be lost or changed. A verified backup is made first. Continue?"
    }
    func confirmLossyApply() {
        apply(override: pendingSourceOverride, allowLossy: true)
    }

    private var revision: String?
    private var dayStart: TimeInterval = 0   // seconds since 2001-01-01 UTC, start of the edited local day
    private var dayEnd: TimeInterval = 0

    var loadNote: String {
        if loaded { return "Showing today's usage as stored on this device. Nothing changes until you tap Apply, and a verified backup is made first." }
        return "Existing usage has not been read. Composed sessions stay in memory only; closing the app discards them."
    }
    var canApply: Bool { capability.canApply && loaded && revision != nil && !busy && !sessions.isEmpty }

    func refreshCapability() {
        busy = true
        Task.detached {
            let r = HelperClient.run(.probe)
            let c = Capability.from(r)
            await MainActor.run { self.capability = c; self.busy = false; if r?.ok == true { self.reload() } }
        }
    }

    /// Reads current usage from the helper, replacing any in-memory edits (used by Reload).
    func reload() {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let ds = start.timeIntervalSinceReferenceDate, de = end.timeIntervalSinceReferenceDate
        busy = true
        Task.detached {
            let reply = HelperClient.run(.read)
            await MainActor.run {
                self.busy = false
                guard let reply else { self.error = "Helper did not answer."; return }
                guard reply.ok, let json = reply.details["snapshot"],
                      let snap = try? JSONDecoder().decode(StorageSnapshot.self, from: Data(json.utf8)) else {
                    self.error = reply.ok ? "Helper returned unreadable usage." : reply.message; return
                }
                self.install(snap, dayStart: ds, dayEnd: de)
            }
        }
    }

    private func install(_ snap: StorageSnapshot, dayStart ds: TimeInterval, dayEnd de: TimeInterval) {
        var out: [UsageSession] = []
        for s in snap.sessions where s.end > ds && s.start < de {
            let u = UsageSession(bundleID: s.bundle, start: max(s.start, ds) - ds, end: min(s.end, de) - ds)
            // Apply rewrites the whole day, so sessions the editor cannot represent must not be silently dropped.
            out.append(u)
        }
        out.sort { $0.start < $1.start }
        sessions = out; dayStart = ds; dayEnd = de; revision = snap.revision; loaded = true
        selected = nil; error = nil
        warnings = snap.warnings
    }

    func add(bundleID: String, start: TimeInterval, end: TimeInterval) {
        let s = UsageSession(bundleID: bundleID, start: SessionRules.snap(start), end: SessionRules.snap(end))
        do { try SessionRules.validate(s); sessions.append(s); sessions.sort { $0.start < $1.start }; selected = s.id; error = nil }
        catch { self.error = "\(error)" }
    }
    func update(_ s: UsageSession) {
        var n = s; n.start = SessionRules.snap(n.start); n.end = SessionRules.snap(n.end)
        do { try SessionRules.validate(n); if let i = sessions.firstIndex(where: { $0.id == n.id }) { sessions[i] = n }; error = nil }
        catch { self.error = "\(error)" }
    }
    func delete(_ id: UUID) { sessions.removeAll { $0.id == id }; if selected == id { selected = nil } }

    /// The helper takes its own fresh, verified backup of the CURRENT sources before every write,
    /// including an override, and refuses to write if it cannot.
    func apply(override: Bool = false, allowLossy: Bool = false) {
        guard canApply, let rev = revision else { error = "Apply is unavailable: \(capability.summary)"; return }
        if uneditableCount > 0 && !allowLossy {
            pendingSourceOverride = override
            showLossyConfirmation = true
            return
        }
        let editable = sessions.filter { (try? SessionRules.validate($0)) != nil }
        for s in editable { do { try SessionRules.validate(s) } catch { self.error = "\(error)"; return } }
        let edit = ApplyRequest(start: dayStart, end: dayEnd,
            sessions: editable.map { StoredSession(bundle: $0.bundleID, start: dayStart + $0.start, end: dayStart + $0.end) },
            revision: rev, overrideSourceChanges: override)
        busy = true; error = nil; status = nil
        Task.detached {
            let a = HelperClient.run(HelperRequest(op: .apply, apply: edit))
            await MainActor.run {
                self.busy = false
                guard let a else { self.error = "Helper did not answer. Check whether anything changed before trying again."; return }
                if a.ok {
                    self.status = a.message
                    self.reload()
                } else if a.code == "stale_revision" && !override {
                    self.showStale = true
                } else {
                    self.error = a.message
                }
            }
        }
    }
}

func formatHM(_ t: TimeInterval) -> String {
    let m = Int(t / 60); return String(format: "%02d:%02d", m / 60, m % 60)
}
func formatDuration(_ t: TimeInterval) -> String {
    let m = Int(t / 60); return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}
