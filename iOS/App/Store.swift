import SwiftUI

@MainActor
final class Store: ObservableObject {
    @Published var sessions: [UsageSession] = []
    @Published var capability: Capability = .unknown("Checking.")
    @Published var error: String?
    @Published var selected: UUID?
    @Published var status: String?

    func refreshCapability() {
        Task.detached {
            let r = HelperClient.run(.probe)
            let c = Capability.from(r)
            await MainActor.run { self.capability = c }
        }
    }
    // Reading real usage needs the helper's read path, which is not implemented. Never invent sessions.
    var loadNote: String { "Existing usage cannot be read yet. You can compose sessions, but they stay local until apply is available." }

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

    func apply() {
        guard capability.canApply else { error = "Apply is unavailable: \(capability.summary)"; return }
        for s in sessions { do { try SessionRules.validate(s) } catch { self.error = "\(error)"; return } }
        let backupID = UUID().uuidString
        Task.detached {
            guard let b = HelperClient.run(.backup, extra: [backupID]), b.ok,
                  let v = HelperClient.run(.verifyBackup, extra: [backupID]), v.ok else {
                await MainActor.run { self.error = "Backup failed. Nothing was changed." }; return
            }
            let a = HelperClient.run(.apply)
            await MainActor.run { self.status = a?.message; if a?.ok != true { self.error = a?.message ?? "Helper did not answer." } }
        }
    }
}

func formatHM(_ t: TimeInterval) -> String {
    let m = Int(t / 60); return String(format: "%02d:%02d", m / 60, m % 60)
}
func formatDuration(_ t: TimeInterval) -> String {
    let m = Int(t / 60); return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
}
