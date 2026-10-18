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

@main struct DateSelectionChecks {
    @MainActor static func main() async {
        var checks = 0
        func check(_ value: Bool) { precondition(value, "check \(checks + 1)"); checks += 1 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/Vancouver")!
        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
            cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }
        // Inclusive 15 local dates across DST, month/year, and leap boundaries.
        for today in [date(2026, 3, 10), date(2026, 11, 3), date(2027, 1, 3), date(2024, 3, 2)] {
            let range = UsageDates.range(now: today, calendar: cal)
            check(cal.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day == 14)
            check(range.upperBound == cal.startOfDay(for: today))
            check(UsageDates.clamped(date(2020, 1, 1), now: today, calendar: cal) == range.lowerBound)
            check(UsageDates.clamped(date(2030, 1, 1), now: today, calendar: cal) == range.upperBound)
            check(UsageDates.clamped(range.lowerBound, now: today, calendar: cal) == range.lowerBound)
        }
        check(UsageDates.interval(for: date(2026, 3, 8), calendar: cal).duration == 23 * 3600)
        check(UsageDates.interval(for: date(2025, 11, 2), calendar: cal).duration == 25 * 3600)
        var utc = cal; utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let instant = date(2026, 10, 18, 23)
        check(UsageDates.range(now: instant, calendar: utc).upperBound != UsageDates.range(now: instant, calendar: cal).upperBound)

        var now = date(2026, 3, 10)
        let store = Store(calendar: cal, now: { now })
        store.capability = .ready
        let target = date(2026, 3, 8)
        let interval = UsageDates.interval(for: target, calendar: cal)
        let ds = interval.start.timeIntervalSinceReferenceDate
        let de = interval.end.timeIntervalSinceReferenceDate
        HelperClient.snapshot = StorageSnapshot(sessions: [
            StoredSession(bundle: "com.example.before", start: ds - 600, end: ds),
            StoredSession(bundle: "com.example.cross", start: ds - 300, end: ds + 600),
            StoredSession(bundle: "com.example.target", start: ds + 3600, end: ds + 7200),
            StoredSession(bundle: "com.example.after", start: de, end: de + 600)
        ], revision: "fixture", warnings: ["fixture warning"])
        store.selectDate(target)
        check(store.selectedDate == interval.start && !store.loaded && !store.canApply)
        while store.busy { await Task.yield() }
        check(store.loaded && store.canApply)
        check(store.sessions.map(\.bundleID) == ["com.example.cross", "com.example.target"])
        check(store.sessions[0].start == 0 && store.sessions[0].end == 600)
        check(HelperClient.requests.isEmpty) // Selection never applies.
        let reads = HelperClient.reads
        store.selectDate(target)
        check(HelperClient.reads == reads && !store.busy)
        store.apply()
        while store.busy { await Task.yield() }
        check(HelperClient.requests.count == 1)
        check(HelperClient.requests[0].start == ds && HelperClient.requests[0].end == de)
        check(HelperClient.requests[0].sessions[0].start == ds)
        check(HelperClient.requests[0].sessions[1].start == ds + 3600)

        // Failed read cannot accidentally Apply the previous date's sessions/revision.
        HelperClient.snapshot = nil
        store.selectDate(date(2020, 1, 1))
        while store.busy { await Task.yield() }
        check(store.selectedDate == store.dateRange.lowerBound)
        check(!store.loaded && !store.canApply && store.sessions.isEmpty && store.error != nil)
        check(store.warnings.isEmpty && !store.showStale && !store.showLossyConfirmation)
        check(HelperClient.requests.count == 1)

        // Day rollover clamps an aged-out selection using calendar arithmetic.
        now = cal.date(byAdding: .day, value: 2, to: now)!
        store.reload()
        while store.busy { await Task.yield() }
        check(store.selectedDate == store.dateRange.lowerBound)
        store.selectDate(date(2030, 1, 1))
        while store.busy { await Task.yield() }
        check(store.selectedDate == store.dateRange.upperBound)
        check(HelperClient.requests.count == 1)
        print("PASS \(checks) calendar boundary, DST/timezone, date load/apply routing and failure checks; mock IPC only")
    }
}
