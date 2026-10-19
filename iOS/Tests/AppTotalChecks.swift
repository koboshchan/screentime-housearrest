import Foundation
import Darwin

@main struct AppTotalChecks {
    static var count = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        count += 1
        if try !value() { throw StorageFailure("test_failed", label) }
    }
    static func rejects(_ label: String, _ work: () throws -> Void) throws {
        var failed = false
        do { try work() } catch { failed = true }
        try check(failed, label)
    }
    static func total(_ data: Data) throws -> Double {
        let value = try NativeAppTotals.SegmentValue(data)
        return try NativeAppTotals.seconds(value.value["totalActivityDuration"])
    }
    static func main() throws {
        NSTimeZone.default = TimeZone(secondsFromGMT:0)!
        for scenario in ["missing Weekly", "sparse Daily", "existing synthetic cache", "unknown category semantics"] {
            do {
                try NativeApplySafety.requireValidatedBaseline()
                throw StorageFailure("test_failed", "quarantine allowed " + scenario)
            } catch let error as StorageFailure {
                try check(error.code == "apply_quarantined", "production safety policy rejects " + scenario)
            }
        }

        let rev = String(repeating: "0", count: 64)
        let request = ApplyRequest(start: 0, end: 86400, sessions: [
            StoredSession(bundle: AppTotalFixtures.a, start: 0, end: 7200),
            StoredSession(bundle: AppTotalFixtures.b, start: 0, end: 7200)], revision: rev)
        let original = try NativeAppTotals.SegmentValue(AppTotalFixtures.bytes(AppTotalFixtures.document(start: 0, duration: 86400)))
        let catalog = try NativeAppTotals.apps(original.value)
        let result = try NativeAppTotals.replacing(original,
            totals: NativeAppTotals.durations(request, start: 0, end: 86400), catalog: catalog)
        try check(try total(result) == 14400, "2h + overlapping 2h = exactly 4h, not union or old 999999")
        let parsed = try NativeAppTotals.SegmentValue(result)
        let cats = parsed.value["categoryActivities"] as! [[String: Any]]
        try check(try cats.reduce(0.0) { try $0 + NativeAppTotals.seconds($1["totalActivityDuration"]) } == 14400, "category totals are app sums only")
        try check((cats[0]["webDomainActivities"] as! [[String: Any]])[0]["domain"] as? String == "example.invalid", "web detail preserved but excluded")
        let repeated = try NativeAppTotals.SegmentValue(NativeAppTotals.replacing(parsed, totals: [AppTotalFixtures.a: 7200, AppTotalFixtures.b: 7200], catalog: catalog))
        try check(NSDictionary(dictionary: repeated.document).isEqual(to: parsed.document), "repeat transform semantically idempotent")
        let lowered = try NativeAppTotals.replacing(original, totals: [AppTotalFixtures.a: 1.25], catalog: catalog)
        try check(try total(lowered) == 1.25, "exact fractional lower total replaces larger old values")
        try check(try total(NativeAppTotals.replacing(original, totals: [:], catalog: catalog)) == 0, "empty edit exactly zero")
        let overday = ApplyRequest(start: 0, end: 86400, sessions: [
            StoredSession(bundle: AppTotalFixtures.a, start: 0, end: 86400),
            StoredSession(bundle: AppTotalFixtures.b, start: 0, end: 86400)], revision: rev)
        try check(try total(NativeAppTotals.replacing(original,
            totals: NativeAppTotals.durations(overday, start: 0, end: 86400), catalog: catalog)) == 172800, "48h not clamped to 24h")
        try check(NativeAppTotals.durations(request, start: 3600, end: 7200).values.reduce(0,+) == 7200, "hourly overlap >1h")
        try rejects("unknown app template fails before write") {
            _ = try NativeAppTotals.replacing(original, totals: ["com.example.unknown": 100], catalog: catalog)
        }
        for bad in [-1.0, Double.nan, Double.infinity] {
            try rejects("invalid app duration") { _ = try NativeAppTotals.replacing(original, totals: [AppTotalFixtures.a: bad], catalog: catalog) }
        }
        try rejects("Boolean duration") { _ = try NativeAppTotals.seconds(true) }
        var duplicate = original.document, value = original.value
        var categories = value["categoryActivities"] as! [[String: Any]]
        var second = categories[1]
        second["applicationActivities"] = categories[0]["applicationActivities"]
        categories[1] = second; value["categoryActivities"] = categories; duplicate["value"] = value
        try rejects("same app in two categories rejected rather than counted twice") {
            _ = try NativeAppTotals.SegmentValue(AppTotalFixtures.bytes(duplicate))
        }

        let base = URL(fileURLWithPath: "/private/tmp/surface-app-sum-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: base) }
        let group = base.appendingPathComponent("groups")
        let root = group.appendingPathComponent("fixture/Library/com.apple.DeviceActivity/Local")
        try AppTotalFixtures.create(root)
        let store = NativeStorage(database: base.appendingPathComponent("unused"), stream: base.appendingPathComponent("unused"),
                                  backups: base.appendingPathComponent("unused"), groupRoot: group)
        let now = Date(timeIntervalSinceReferenceDate: 100000)
        let before = try boundedBytes(root.appendingPathComponent("Daily/ActivitySegments/0.0.plist"))
        let plans = try store.prepareAppTotals(request, now: now)
        try check(try boundedBytes(root.appendingPathComponent("Daily/ActivitySegments/0.0.plist")) == before, "planning read-only")
        try check(plans.count == 29, "day + week + 24 DST-aware hours + 3 metadata")
        try check(plans.suffix(3).allSatisfy { $0.path.lastPathComponent == "Metadata.plist" }, "freeze metadata last")
        let weekly = plans.first { $0.path.path.contains("/Weekly/ActivitySegments/") }!
        try check(try total(weekly.replacement) == 14800, "weekly retains other-day app totals, excludes category/web/old total")
        let hours = plans.filter { $0.path.path.contains("/Hourly/ActivitySegments/") }
        try check(try hours.reduce(0.0) { try $0 + total($1.replacement) } == 14400, "hourly sum equals exact daily sum")
        try check(hours.filter { $0.original == nil }.count == 23, "missing/future hours use deterministic templates")
        for plan in plans { try store.writeAppTotal(plan) }
        try check(try total(boundedBytes(root.appendingPathComponent("Daily/ActivitySegments/0.0.plist"))) == 14400, "native cache write")
        let created = root.appendingPathComponent("Hourly/ActivitySegments/3600.0.plist")
        let sourceMode = try store.metadata(root.appendingPathComponent("Hourly/ActivitySegments/0.0.plist"))
        let newMode = try store.metadata(created)
        try check(sourceMode.0 == newMode.0 && sourceMode.1 == newMode.1 && sourceMode.2 == newMode.2, "created hour retains uid/gid/mode")
        let futureHour = try NativeAppTotals.SegmentValue(boundedBytes(root.appendingPathComponent("Hourly/ActivitySegments/82800.0.plist")))
        try check(futureHour.start == 82800 && futureHour.end == 86400, "new hour interval not copied from source")
        try check(try total(boundedBytes(root.appendingPathComponent("Hourly/ActivitySegments/82800.0.plist"))) == 0, "future empty hour has no invented usage")
        try rejects("exclusive create rejects concurrent daemon file") { try store.writeAppTotal(hours.first { $0.original == nil }!) }
        let oldPlan = plans.first!
        try rejects("stale existing cache bytes rejected") { try store.writeAppTotal(oldPlan) }
        let secondPlans = try store.prepareAppTotals(request, now: now)
        try check(try total(secondPlans.first!.replacement) == 14400, "repeat Apply exact not accumulating")
        let secondWeekly = secondPlans.first { $0.path.path.contains("/Weekly/ActivitySegments/") }!
        try check(try total(secondWeekly.replacement) == 14800, "repeat weekly delta idempotent")
        let empty = ApplyRequest(start: 0, end: 86400, sessions: [], revision: rev)
        let cleared = try store.prepareAppTotals(empty, now: now)
        try check(try total(cleared.first!.replacement) == 0, "clear day replaces old larger total")
        try check(try total(cleared.first { $0.path.path.contains("/Weekly/ActivitySegments/") }!.replacement) == 400, "clear retains week outside edited day")

        for plan in plans.suffix(3) {
            let doc = try PropertyListSerialization.propertyList(from: plan.replacement, format: nil) as! [String: Any]
            let metadata = doc["value"] as! [String: Any]
            try check(metadata["lastUpdatedDate"] as? Date == now.addingTimeInterval(30*86400), "dynamic future metadata")
            try check(metadata["untouched"] as? String == "sentinel", "metadata unrelated keys preserved")
        }
        let longer = now.addingTimeInterval(90*86400)
        let meta = try AppTotalFixtures.bytes(["value": ["lastUpdatedDate": longer]])
        let extended = try PropertyListSerialization.propertyList(from: NativeAppTotals.metadata(meta, until: now), format: nil) as! [String: Any]
        try check((extended["value"] as! [String: Any])["lastUpdatedDate"] as? Date == longer, "never shorten existing longer future refresh hold")
        try rejects("missing metadata date fails closed") {
            _ = try NativeAppTotals.metadata(AppTotalFixtures.bytes(["value": [:]]), until: now)
        }
        let badDaily = root.appendingPathComponent("Daily/ActivitySegments/0.0.plist")
        var inconsistent = AppTotalFixtures.document(start: 0, duration: 86400, a: 9999999, b: 0)
        try store.writeExisting(badDaily, original: boundedBytes(badDaily), replacement: AppTotalFixtures.bytes(inconsistent))
        try rejects("inconsistent daily/weekly fails closed") { _ = try store.prepareAppTotals(request, now: now) }
        inconsistent = AppTotalFixtures.document(start: 0, duration: 86400)
        try store.writeExisting(badDaily, original: boundedBytes(badDaily), replacement: AppTotalFixtures.bytes(inconsistent))
        let linked = root.appendingPathComponent("Hourly/ActivitySegments/7200.0.plist")
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: badDaily)
        try rejects("symlink cache rejected") { _ = try store.prepareAppTotals(request, now: now) }
        try FileManager.default.removeItem(at: linked)

        // Real fresh-device layout can have empty or absent granularity dirs.
        // These are lazy native caches, not permission to invent private records.
        for gran in ["Hourly","Daily","Weekly"] {
            for absentDirectory in [false,true] {
                let sparseGroup = base.appendingPathComponent("sparse-" + gran + String(absentDirectory))
                let sparseRoot = sparseGroup.appendingPathComponent("fixture/Library/com.apple.DeviceActivity/Local")
                try AppTotalFixtures.create(sparseRoot)
                let directory = sparseRoot.appendingPathComponent(gran + "/ActivitySegments")
                try FileManager.default.removeItem(at:directory)
                if !absentDirectory { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
                let sparseStore = NativeStorage(database:base.appendingPathComponent("unused"),stream:base.appendingPathComponent("unused"),
                                                backups:base.appendingPathComponent("no-backup"),groupRoot:sparseGroup)
                let marker = sparseRoot.appendingPathComponent("Hourly/Metadata.plist")
                let prior = try boundedBytes(marker)
                var message = ""
                do { _ = try sparseStore.prepareAppTotals(request,now:now) }
                catch { message = String(describing:error) }
                if gran != "Hourly" && !absentDirectory {
                    try check(message.isEmpty, "missing Daily file synthesizes without native Settings generation")
                } else {
                    try check(message.contains(gran) && message.contains("Screen Time") && message.contains("Nothing applied"),
                              "missing required native directory/template fails closed")
                }
                try check(try boundedBytes(marker) == prior,"missing-cache preflight leaves native metadata unchanged")
                try check(!FileManager.default.fileExists(atPath:base.appendingPathComponent("no-backup").path),
                          "missing native cache creates no backup or usage write")
                if absentDirectory { try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true) }
                try privateWrite(AppTotalFixtures.bytes(AppTotalFixtures.document(start:0,
                    duration:gran == "Hourly" ? 3600 : (gran == "Daily" ? 86400 : 604800),a:100,b:100)),
                    directory.appendingPathComponent("0.0.plist"))
                // Native regeneration, not a cached negative result, unblocks the next preflight.
                try check(try sparseStore.prepareAppTotals(request,now:now).count == 29,
                          "fresh native templates are rediscovered on next attempt")
            }
        }
        let synthesisGroup = base.appendingPathComponent("synthesis")
        let synthesisRoot = synthesisGroup.appendingPathComponent("fixture/Library/com.apple.DeviceActivity/Local")
        try AppTotalFixtures.create(synthesisRoot)
        let synthesisStore = NativeStorage(database:base.appendingPathComponent("unused"), stream:base.appendingPathComponent("unused"),
            backups:base.appendingPathComponent("no-backup"), groupRoot:synthesisGroup)
        let missingDaily = synthesisRoot.appendingPathComponent("Daily/ActivitySegments/0.0.plist")
        try FileManager.default.removeItem(at:missingDaily)
        let nativeWeek = synthesisRoot.appendingPathComponent("Weekly/ActivitySegments/0.0.plist")
        var weekDoc = try NativeAppTotals.SegmentValue(boundedBytes(nativeWeek)).document
        var weekVal = weekDoc["value"] as! [String:Any]
        weekVal["recordSystemFields"] = Data([1,2,3])
        weekDoc["value"] = weekVal
        try synthesisStore.writeExisting(nativeWeek,original:boundedBytes(nativeWeek),replacement:AppTotalFixtures.bytes(weekDoc))
        let weekBefore = try boundedBytes(nativeWeek)
        let synthPlans = try synthesisStore.prepareAppTotals(request,now:now)
        let synthDay = synthPlans.first!
        try check(synthDay.original == nil && synthDay.path == missingDaily, "missing Daily exclusive-create plan")
        try check(!FileManager.default.fileExists(atPath:missingDaily.path) && boundedBytes(nativeWeek) == weekBefore,
                  "Daily synthesis is read-only until existing verified-backup mutation path")
        let synthParsed = try NativeAppTotals.SegmentValue(synthDay.replacement)
        try check(synthParsed.start == 0 && synthParsed.end == 86400 && total(synthDay.replacement) == 14400,
                  "synthesized Daily has exact selected interval and overlapping apps-only total")
        try check(synthParsed.value["recordSystemFields"] == nil && synthParsed.value["firstPickup"] == nil &&
                  synthParsed.value["longestActivity"] == nil, "new Daily strips native record identity and stale event details")
        try check(try total(synthPlans.first { $0.path == nativeWeek }!.replacement) == 14800,
                  "missing Daily weekly delta subtracts observed old hourly baseline and preserves 400 outside-day seconds")
        try check((synthParsed.value["categoryActivities"] as! [[String:Any]]).allSatisfy {
            ($0["webDomainActivities"] as! [[String:Any]]).isEmpty
        }, "Daily synthesis does not clone unrelated browsing details")
        let observedHour = synthesisRoot.appendingPathComponent("Hourly/ActivitySegments/0.0.plist")
        var badHourDoc = try NativeAppTotals.SegmentValue(boundedBytes(observedHour)).document
        var badHourVal = badHourDoc["value"] as! [String:Any]
        badHourVal["unknownIdentity"] = "unsafe"
        badHourDoc["value"] = badHourVal
        let observedBefore = try boundedBytes(observedHour)
        try synthesisStore.writeExisting(observedHour,original:observedBefore,replacement:AppTotalFixtures.bytes(badHourDoc))
        try rejects("missing Daily unknown cross-granularity schema fails closed") { _ = try synthesisStore.prepareAppTotals(request,now:now) }
        try synthesisStore.writeExisting(observedHour,original:boundedBytes(observedHour),replacement:observedBefore)
        try synthesisStore.writeExisting(nativeWeek,original:weekBefore,
            replacement:AppTotalFixtures.bytes(AppTotalFixtures.document(start:0,duration:604800,a:1,b:1)))
        try rejects("missing Daily baseline larger than Weekly fails closed") { _ = try synthesisStore.prepareAppTotals(request,now:now) }
        try synthesisStore.writeExisting(nativeWeek,original:boundedBytes(nativeWeek),replacement:weekBefore)
        let dailyMeta = synthesisRoot.appendingPathComponent("Daily/Metadata.plist")
        let savedMeta = try boundedBytes(dailyMeta)
        try FileManager.default.removeItem(at:dailyMeta)
        // A metadata template with an unknown field must still fail closed.
        try rejects("unknown Hourly metadata cannot invent missing Daily metadata") { _ = try synthesisStore.prepareAppTotals(request,now:now) }
        try privateWrite(savedMeta,dailyMeta)
        try synthesisStore.writeAppTotal(synthDay)
        try check(try boundedBytes(missingDaily) == synthDay.replacement, "new Daily fixture exclusive create writes planned bytes")
        try rejects("new Daily exclusive create refuses daemon race") { try synthesisStore.writeAppTotal(synthDay) }

        let bothGroup = base.appendingPathComponent("both-missing")
        let bothRoot = bothGroup.appendingPathComponent("fixture/Library/com.apple.DeviceActivity/Local")
        try AppTotalFixtures.create(bothRoot)
        let bothStore = NativeStorage(database:base.appendingPathComponent("unused"),stream:base.appendingPathComponent("unused"),
            backups:base.appendingPathComponent("no-backup"),groupRoot:bothGroup)
        for gran in ["Daily","Weekly"] {
            try FileManager.default.removeItem(at:bothRoot.appendingPathComponent(gran + "/ActivitySegments/0.0.plist"))
            try FileManager.default.removeItem(at:bothRoot.appendingPathComponent(gran + "/Metadata.plist"))
        }
        let hourlyMetaPath = bothRoot.appendingPathComponent("Hourly/Metadata.plist")
        var hourlyMetaDoc = try PropertyListSerialization.propertyList(from:boundedBytes(hourlyMetaPath),format:nil) as! [String:Any]
        var hourlyMetaValue = hourlyMetaDoc["value"] as! [String:Any]
        hourlyMetaValue.removeValue(forKey:"untouched")
        hourlyMetaValue["recordSystemFields"] = Data([1,2,3])
        hourlyMetaDoc["value"] = hourlyMetaValue
        try bothStore.writeExisting(hourlyMetaPath,original:boundedBytes(hourlyMetaPath),replacement:AppTotalFixtures.bytes(hourlyMetaDoc))
        // Outside-day data must survive, including apps not edited today.
        let outsideHour = bothRoot.appendingPathComponent("Hourly/ActivitySegments/90000.0.plist")
        try privateWrite(AppTotalFixtures.bytes(AppTotalFixtures.document(start:90000,duration:3600,a:432,b:678)),outsideHour)
        let bothPlans = try bothStore.prepareAppTotals(request,now:now)
        let bothWeek = bothPlans.first { $0.path.path.contains("/Weekly/ActivitySegments/") }!
        try check(bothWeek.original == nil && total(bothWeek.replacement) == 15510,
                  "both missing preserves 1110 outside-day seconds plus exact 14400 edited seconds")
        let weekParsed = try NativeAppTotals.SegmentValue(bothWeek.replacement)
        try check(weekParsed.start == 0 && weekParsed.end == 604800, "native Monday week boundary from local metadata")
        try check(bothPlans.suffix(2).allSatisfy { $0.original == nil }, "both missing metadata uses exclusive creation")
        for (gran,code) in [("Daily",1),("Weekly",2)] {
            let data = bothPlans.first { $0.path.path.hasSuffix(gran + "/Metadata.plist") }!.replacement
            let doc = try PropertyListSerialization.propertyList(from:data,format:nil) as! [String:Any]
            let value = doc["value"] as! [String:Any]
            try check(value["segmentInterval"] as? Int == code && value["recordName"] as? String ==
                      "00000000-0000-4000-8000-000000000000_" + gran, "native metadata enum and same-device record suffix")
            try check(value["recordSystemFields"] == nil &&
                NSDictionary(dictionary:value["device"] as! [String:Any]).isEqual(to:hourlyMetaValue["device"] as! [String:Any]),
                "synthesized metadata strips CloudKit system identity, retains this device only")
        }
        try check(!FileManager.default.fileExists(atPath:bothWeek.path.path), "both-missing planning remains read-only")
        for plan in bothPlans { try bothStore.writeAppTotal(plan) }
        let repeatedBoth = try bothStore.prepareAppTotals(request,now:now)
        try check(try total(repeatedBoth.first { $0.path.path.contains("/Weekly/ActivitySegments/") }!.replacement) == 15510,
                  "both-missing repeat does not accumulate or erase outside-day totals")
        let outsideObserved = try boundedBytes(outsideHour)
        try check(try total(outsideObserved) == 999999, "outside-day hourly bytes unchanged")
        // Native Sunday-start calendar must not be silently treated as Monday.
        let calendarPath = bothRoot.deletingLastPathComponent().appendingPathComponent("LocalFirstWeekday.plist")
        try bothStore.writeExisting(calendarPath,original:boundedBytes(calendarPath),replacement:AppTotalFixtures.bytes(["value":1]))
        let sunday = try bothStore.cacheCalendar(bothRoot).dateInterval(of:.weekOfYear,for:Date(timeIntervalSinceReferenceDate:0))!
        try check(sunday.start.timeIntervalSinceReferenceDate == -86400, "native Sunday firstWeekday respected")
        // DST week is calendar arithmetic, not a hardcoded 604800 seconds.
        let zonePath = bothRoot.deletingLastPathComponent().appendingPathComponent("LocalTimeZone.plist")
        try bothStore.writeExisting(zonePath,original:boundedBytes(zonePath),replacement:AppTotalFixtures.bytes(["value":["identifier":"America/Vancouver"]]))
        try bothStore.writeExisting(calendarPath,original:boundedBytes(calendarPath),replacement:AppTotalFixtures.bytes(["value":2]))
        let march = ISO8601DateFormatter().date(from:"2026-03-08T12:00:00Z")!
        let dstWeek = try bothStore.cacheCalendar(bothRoot).dateInterval(of:.weekOfYear,for:march)!
        try check(dstWeek.duration == 601200, "native DST week has 167 hours")
        for length in [82800.0, 90000.0] {
            let dstGroup = base.appendingPathComponent("dst-" + String(Int(length)))
            let dstRoot = dstGroup.appendingPathComponent("fixture/Library/com.apple.DeviceActivity/Local")
            try AppTotalFixtures.create(dstRoot, duration: length)
            let dstStore = NativeStorage(database: base.appendingPathComponent("unused"), stream: base.appendingPathComponent("unused"),
                backups: base.appendingPathComponent("unused"), groupRoot: dstGroup)
            let edit = ApplyRequest(start: 0, end: length, sessions: [StoredSession(bundle: AppTotalFixtures.a, start: 0, end: length)], revision: rev)
            let dstPlans = try dstStore.prepareAppTotals(edit, now: now)
            let dstHours = dstPlans.filter { $0.path.path.contains("/Hourly/ActivitySegments/") }
            try check(dstHours.count == Int(length/3600), "23/25h DST hour count")
            try check(try dstHours.reduce(0.0) { try $0 + total($1.replacement) } == length, "DST exact unclamped sum")
        }
        print("PASS native apps-only cache \(count) checks; synthetic files only")
    }
}
