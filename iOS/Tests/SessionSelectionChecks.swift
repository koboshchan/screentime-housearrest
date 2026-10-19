import Foundation

// Mock IPC only. These checks cannot start the privileged helper or write usage.
enum HelperClient {
    static var snapshot: StorageSnapshot?
    static var requests: [ApplyRequest] = []
    static var reads = 0
    static func run(_ op: HelperOp) -> HelperReply? {
        reads += 1
        guard let snapshot else { return nil }
        return HelperReply(ok: true, code: "ok", message: "", details: [
            "snapshot": String(data: try! JSONEncoder().encode(snapshot), encoding: .utf8)!
        ])
    }
    static func run(_ request: HelperRequest) -> HelperReply? {
        if let edit = request.apply { requests.append(edit) }
        return HelperReply(ok: false, code: "fixture", message: "Mock transport")
    }
}

@main struct SessionSelectionChecks {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: Bool) { precondition(value, "check \(checks + 1)"); checks += 1 }
        let store = Store()
        store.loaded = true
        let a = UsageSession(bundleID: "a", start: 0, end: 60)
        let b = UsageSession(bundleID: "b", start: 120, end: 180)
        let c = UsageSession(bundleID: "c", start: 240, end: 300)
        store.sessions = [a,b,c]
        store.selected = b.id
        store.selectingSessions = true
        store.selectedSessions = [a.id,b.id]
        store.requestSessionDeletion(store.selectedSessions)
        check(store.showDeleteConfirmation)
        check(store.sessions.map(\.id) == [a.id,b.id,c.id])
        check(HelperClient.requests.isEmpty && HelperClient.reads == 0)
        store.cancelSessionDeletion()
        check(!store.showDeleteConfirmation && store.sessions.count == 3)
        store.confirmSessionDeletion()
        check(store.sessions.count == 3)
        store.requestSessionDeletion([a.id,b.id])
        // Row order may change while confirmation is displayed. Delete by ID.
        store.sessions = [c,b,a]
        store.confirmSessionDeletion()
        check(store.sessions.map(\.id) == [c.id])
        check(store.selected == nil && store.selectedSessions.isEmpty)
        check(!store.showDeleteConfirmation)
        check(HelperClient.requests.isEmpty && HelperClient.reads == 0)
        check(store.loaded && store.status?.contains("draft") == true)
        store.requestSessionDeletion([UUID()])
        check(!store.showDeleteConfirmation)
        store.busy = true
        store.requestSessionDeletion([c.id])
        check(!store.showDeleteConfirmation && store.sessions.map(\.id) == [c.id])
        store.busy = false
        store.requestSessionDeletion([c.id])
        store.busy = true
        store.confirmSessionDeletion()
        check(store.sessions.map(\.id) == [c.id] && !store.showDeleteConfirmation)
        store.busy = false
        store.requestSessionDeletion([c.id])
        store.confirmSessionDeletion()
        check(store.sessions.isEmpty) // Delete every row in memory, no implicit Apply.
        check(HelperClient.requests.isEmpty && HelperClient.reads == 0)
        store.sessions = [a,b,c]
        store.selectedSessions = [a.id,c.id]
        store.requestSessionDeletion(store.selectedSessions)
        store.finishSelectingSessions()
        check(!store.selectingSessions && store.selectedSessions.isEmpty && !store.showDeleteConfirmation)
        store.confirmSessionDeletion()
        check(store.sessions.count == 3)
        store.selectingSessions = true
        store.selectedSessions = [b.id]
        store.requestSessionDeletion([b.id])
        store.reload()
        while store.busy { await Task.yield() }
        check(!store.selectingSessions && store.selectedSessions.isEmpty && !store.showDeleteConfirmation)
        check(store.sessions.isEmpty && !store.loaded)
        check(HelperClient.requests.isEmpty && HelperClient.reads == 1)
        // An empty draft remains explicitly applicable after deleting every loaded row.
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        HelperClient.snapshot = StorageSnapshot(sessions: [
            StoredSession(bundle: "fixture", start: day + 60, end: day + 120)
        ], revision: "fixture", warnings: [])
        store.capability = .ready
        store.reload()
        while store.busy { await Task.yield() }
        store.requestSessionDeletion(Set(store.sessions.map(\.id)))
        store.confirmSessionDeletion()
        check(store.sessions.isEmpty && store.canApply)
        check(HelperClient.requests.isEmpty)
        store.apply()
        while store.busy { await Task.yield() }
        check(HelperClient.requests.count == 1 && HelperClient.requests[0].sessions.isEmpty)
        print("PASS \(checks) multi-selection, confirm/cancel, stable IDs, busy/reload reset and draft-only deletion checks; mock IPC only")
    }
}
