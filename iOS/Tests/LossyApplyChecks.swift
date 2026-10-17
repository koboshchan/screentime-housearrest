import Foundation

// Test-only transport: no helper process, storage access or device writes.
enum HelperClient {
    static var requests: [ApplyRequest] = []
    static func run(_ op: HelperOp) -> HelperReply? {
        let day = Calendar.current.startOfDay(for: Date()).timeIntervalSinceReferenceDate
        let snapshot = StorageSnapshot(sessions: [
            StoredSession(bundle: "com.example.good", start: day + 100, end: day + 220),
            StoredSession(bundle: "com.example.short", start: day + 300, end: day + 310)
        ], revision: "fixture", warnings: [])
        return HelperReply(ok: true, code: "ok", message: "", details: [
            "snapshot": String(data: try! JSONEncoder().encode(snapshot), encoding: .utf8)!
        ])
    }
    static func run(_ request: HelperRequest) -> HelperReply? {
        if let edit = request.apply { requests.append(edit) }
        return HelperReply(ok: false, code: "fixture", message: "Test transport only")
    }
}
@main struct LossyApplyChecks {
    @MainActor static func main() async {
        let store = Store()
        store.capability = .ready
        store.reload()
        while store.busy { await Task.yield() }
        precondition(store.canApply && store.uneditableCount == 1)
        store.apply()
        precondition(store.showLossyConfirmation && HelperClient.requests.isEmpty)
        store.showLossyConfirmation = false // Cancel leaves everything intact
        precondition(store.sessions.count == 2 && HelperClient.requests.isEmpty)
        store.confirmLossyApply()
        while store.busy { await Task.yield() }
        precondition(HelperClient.requests.count == 1)
        precondition(HelperClient.requests[0].sessions.count == 1)
        precondition(HelperClient.requests[0].sessions[0].bundle == "com.example.good")
        precondition(!HelperClient.requests[0].overrideSourceChanges)
        store.apply(override: true)
        precondition(store.showLossyConfirmation && HelperClient.requests.count == 1)
        store.confirmLossyApply()
        while store.busy { await Task.yield() }
        precondition(HelperClient.requests.count == 2 && HelperClient.requests[1].overrideSourceChanges)
        store.capability = .unknown("fixture")
        store.apply(allowLossy: true)
        precondition(HelperClient.requests.count == 2)
        print("9 lossy confirmation, cancel, filter, source override and capability checks passed; mock transport only")
    }
}
