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
        try NativeAppTotals.seconds(NativeAppTotals.SegmentValue(data).value["totalActivityDuration"])
    }
    static func bytes(_ value: Any) throws -> Data {
        // Stable field encoding, independent of binary-plist dictionary table order.
        if let dictionary = value as? [String: Any] {
            var result = Data("dict".utf8)
            for key in dictionary.keys.sorted() {
                let field = try bytes(dictionary[key]!)
                result.append(Data("\(key.utf8.count):\(key)\(field.count):".utf8)); result.append(field)
            }
            return result
        }
        if let array = value as? [Any] {
            var result = Data("array".utf8)
            for item in array { let field = try bytes(item); result.append(Data("\(field.count):".utf8)); result.append(field) }
            return result
        }
        return try PropertyListSerialization.data(fromPropertyList: [value], format: .binary, options: 0)
    }
    static func assertCategories(_ old: Data, _ new: Data) throws {
        let a = try NativeAppTotals.SegmentValue(old), b = try NativeAppTotals.SegmentValue(new)
        let ac = a.value["categoryActivities"] as! [[String: Any]]
        let bc = b.value["categoryActivities"] as! [[String: Any]]
        for (x,y) in zip(ac,bc) {
            var x = x, y = y
            let xa = x.removeValue(forKey:"applicationActivities") as! [[String:Any]]
            let ya = y.removeValue(forKey:"applicationActivities") as! [[String:Any]]
            let sum = try ya.reduce(0.0) { try $0 + NativeAppTotals.seconds($1["totalActivityDuration"]) }
            try check(try NativeAppTotals.seconds(y["totalActivityDuration"]) == sum, "category total equals apps-only sum including overlap")
            x.removeValue(forKey:"totalActivityDuration"); y.removeValue(forKey:"totalActivityDuration")
            try check(try bytes(x) == bytes(y), "web data and unrelated category fields byte-identical")
            for (u,v) in zip(xa,ya) {
                var u = u, v = v
                u.removeValue(forKey:"totalActivityDuration"); v.removeValue(forKey:"totalActivityDuration")
                try check(try bytes(u) == bytes(v), "app unrelated fields byte-identical")
            }
        }
        var av = a.value, bv = b.value
        for key in ["categoryActivities","totalActivityDuration"] { av.removeValue(forKey:key); bv.removeValue(forKey:key) }
        try check(try bytes(av) == bytes(bv), "unrelated segment fields byte-identical")
    }
    static func main() throws {
        for minor in 0...5 {
            try rejects("older iOS 18 refuses unsafe future refresh") {
                try NativeAppTotals.requireSafeFutureRefresh(OperatingSystemVersion(majorVersion:18,minorVersion:minor,patchVersion:0))
            }
        }
        try NativeAppTotals.requireSafeFutureRefresh(OperatingSystemVersion(majorVersion:18,minorVersion:6,patchVersion:2))
        NSTimeZone.default = TimeZone(secondsFromGMT:0)!
        let rev = String(repeating:"0",count:64)
        let request = ApplyRequest(start:0,end:86400,sessions:[
            StoredSession(bundle:AppTotalFixtures.a,start:0,end:7200),
            StoredSession(bundle:AppTotalFixtures.b,start:0,end:7200)],revision:rev)
        let original = try AppTotalFixtures.bytes(AppTotalFixtures.document(start:0,duration:86400))
        let parsed = try NativeAppTotals.SegmentValue(original)
        let catalog = try NativeAppTotals.apps(parsed.value)
        let changed = try NativeAppTotals.replacing(parsed,totals:NativeAppTotals.durations(request,start:0,end:86400),catalog:catalog)
        try check(try total(changed) == 14400,"overlapping 2h+2h equals 4h")
        try assertCategories(original,changed)
        let cats = try NativeAppTotals.SegmentValue(changed).value["categoryActivities"] as! [[String:Any]]
        try check(try cats.reduce(0.0) { try $0 + NativeAppTotals.seconds($1["totalActivityDuration"]) } == total(changed),"displayed category sum matches segment total, excluding web duplicates")
        var sameDoc = parsed.document, sameValue = parsed.value
        var sameCats = sameValue["categoryActivities"] as! [[String:Any]]
        sameCats[0]["applicationActivities"] = (sameCats[0]["applicationActivities"] as! [[String:Any]]) + (sameCats[1]["applicationActivities"] as! [[String:Any]])
        sameCats.removeLast(); sameValue["categoryActivities"] = sameCats; sameDoc["value"] = sameValue
        let sameBytes = try AppTotalFixtures.bytes(sameDoc)
        let same = try NativeAppTotals.replacing(NativeAppTotals.SegmentValue(sameBytes),totals:[AppTotalFixtures.a:86400,AppTotalFixtures.b:86400],catalog:catalog)
        let sameOut = try NativeAppTotals.SegmentValue(same).value["categoryActivities"] as! [[String:Any]]
        try check(try NativeAppTotals.seconds(sameOut[0]["totalActivityDuration"]) == 172800,"same-category two overlapping apps sum to 48h, not union or cap")
        try assertCategories(sameBytes,same)
        let emptyHour = try NativeAppTotals.blank(parsed,start:0,duration:3600)
        let introduced = try NativeAppTotals.synthesized(emptyHour,totals:[AppTotalFixtures.a:3600,AppTotalFixtures.b:3600],catalog:catalog)
        let introducedCats = try NativeAppTotals.SegmentValue(introduced).value["categoryActivities"] as! [[String:Any]]
        try check(introducedCats.count == 2,"trusted categories introduced into empty hour")
        try check(try introducedCats.allSatisfy { try NativeAppTotals.seconds($0["totalActivityDuration"]) == 3600 },"new categories no longer have zero totals")
        try check(try total(introduced) == 7200,"new hour retains overlapping app sum")
        let keepB = try NativeAppTotals.replacing(parsed,totals:[AppTotalFixtures.a:7200,AppTotalFixtures.b:100],catalog:catalog)
        try assertCategories(original,keepB)
        let newCats = try NativeAppTotals.SegmentValue(keepB).value["categoryActivities"] as! [[String:Any]]
        try check(try NativeAppTotals.seconds(newCats[1]["totalActivityDuration"]) == 100,"unchanged app still repairs stale category aggregate")
        for amounts in [[AppTotalFixtures.a:1.25],[:],[AppTotalFixtures.a:86400,AppTotalFixtures.b:86400]] {
            let output = try NativeAppTotals.replacing(parsed,totals:amounts,catalog:catalog)
            try check(try total(output) == amounts.values.reduce(0,+),"exact fractional/zero/48h apps-only total")
            try assertCategories(original,output)
        }
        try rejects("unknown app fails") { _ = try NativeAppTotals.replacing(parsed,totals:["com.example.unknown":60],catalog:catalog) }
        for bad in [-1.0,Double.nan,Double.infinity] {
            try rejects("bad durations fail") { _ = try NativeAppTotals.replacing(parsed,totals:[AppTotalFixtures.a:bad],catalog:catalog) }
        }
        try rejects("bool duration fails") { _ = try NativeAppTotals.seconds(true) }
        let base = URL(fileURLWithPath:"/private/tmp/surface-preserve-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let group = base.appendingPathComponent("groups")
        let root = group.appendingPathComponent("fixture/Library/com.apple.DeviceActivity/Local")
        try AppTotalFixtures.create(root)
        let store = NativeStorage(database:base.appendingPathComponent("unused"),stream:base.appendingPathComponent("unused"),backups:base.appendingPathComponent("Backups"),groupRoot:group)
        let now = Date(timeIntervalSinceReferenceDate:100000)
        let daily = root.appendingPathComponent("Daily/ActivitySegments/0.0.plist")
        let weekly = root.appendingPathComponent("Weekly/ActivitySegments/0.0.plist")
        let outside = root.appendingPathComponent("Hourly/ActivitySegments/90000.0.plist")
        try privateWrite(AppTotalFixtures.bytes(AppTotalFixtures.document(start:90000,duration:3600,a:123,b:277)),outside)
        let outsideBytes = try boundedBytes(outside)
        let beforeDay = try boundedBytes(daily), beforeWeek = try boundedBytes(weekly)
        let plans = try store.prepareAppTotals(request,now:now)
        try check(plans.count == 29,"complete native unequal-category production planner succeeds")
        try check(try boundedBytes(daily) == beforeDay && boundedBytes(weekly) == beforeWeek,"full planning is read-only")
        try check(!FileManager.default.fileExists(atPath:store.backups.path),"read-only planning creates no backup")
        try check(try total(plans[0].replacement) == 14400,"selected day exact total")
        let weekPlan = plans.first { $0.path == weekly }!
        try check(try total(weekPlan.replacement) == 14800,"native weekly preserves 400 outside-day seconds")
        try assertCategories(beforeDay,plans[0].replacement)
        try assertCategories(beforeWeek,weekPlan.replacement)
        let weekOldApps = try NativeAppTotals.apps(NativeAppTotals.SegmentValue(beforeWeek).value)
        let dayOldApps = try NativeAppTotals.apps(NativeAppTotals.SegmentValue(beforeDay).value)
        let weekNewApps = try NativeAppTotals.apps(NativeAppTotals.SegmentValue(weekPlan.replacement).value)
        for bundle in [AppTotalFixtures.a,AppTotalFixtures.b] {
            try check(weekNewApps[bundle]!.duration-7200 == weekOldApps[bundle]!.duration-dayOldApps[bundle]!.duration,"per-app outside-day weekly contribution exact")
        }
        try check(!plans.contains { $0.path == outside } && boundedBytes(outside) == outsideBytes,"other-day cache bytes untouched")
        let future = now.addingTimeInterval(90*86400)
        for gran in ["Hourly","Daily","Weekly"] {
            let path = root.appendingPathComponent(gran+"/Metadata.plist")
            let old = try boundedBytes(path)
            try store.writeExisting(path,original:old,replacement:NativeAppTotals.metadata(old,until:future))
        }
        let futurePlans = try store.prepareAppTotals(request,now:now)
        try check(futurePlans.count == 29,"future timestamp alone does not reject valid native baseline")
        for plan in futurePlans.suffix(3) {
            let doc = try PropertyListSerialization.propertyList(from:plan.replacement,format:nil) as! [String:Any]
            try check((doc["value"] as! [String:Any])["lastUpdatedDate"] as? Date == future,"longer future hold preserved")
        }
        for gran in ["Daily","Weekly"] {
            let path = root.appendingPathComponent(gran+"/ActivitySegments/0.0.plist")
            let saved = try boundedBytes(path)
            try FileManager.default.removeItem(at:path)
            let metaPath = root.appendingPathComponent("Hourly/Metadata.plist"), meta = try boundedBytes(metaPath)
            try rejects("unknown \(gran) baseline fails before all writes") { _ = try store.prepareAppTotals(request,now:now) }
            try check(!FileManager.default.fileExists(atPath:path.path) && boundedBytes(metaPath) == meta && boundedBytes(outside) == outsideBytes,"unknown baseline has no usage, metadata or outside write")
            try check(!FileManager.default.fileExists(atPath:store.backups.path),"unknown baseline creates no backup")
            try privateWrite(saved,path)
        }
        for plan in futurePlans { try store.writeAppTotal(plan) } // disposable fixture only
        let repeatPlans = try store.prepareAppTotals(request,now:now)
        try check(try total(repeatPlans.first{$0.path == weekly}!.replacement) == 14800,"repeat planning idempotent, existing future hold accepted")
        let empty = ApplyRequest(start:0,end:86400,sessions:[],revision:rev)
        let emptyPlans = try store.prepareAppTotals(empty,now:now)
        try check(try total(emptyPlans.first{$0.path == weekly}!.replacement) == 400,"clear day retains native outside-week contribution")
        try check(try boundedBytes(outside) == outsideBytes,"fixture writes leave other day untouched")
        for length in [82800.0,90000.0] {
            let g = base.appendingPathComponent("dst"+String(length)), r = g.appendingPathComponent("fixture/Library/com.apple.DeviceActivity/Local")
            try AppTotalFixtures.create(r,duration:length)
            let st = NativeStorage(database:base.appendingPathComponent("unused"),stream:base.appendingPathComponent("unused"),backups:base.appendingPathComponent("unused"),groupRoot:g)
            let edit = ApplyRequest(start:0,end:length,sessions:[StoredSession(bundle:AppTotalFixtures.a,start:0,end:length)],revision:rev)
            let p = try st.prepareAppTotals(edit,now:now)
            try check(p.filter{$0.path.path.contains("Hourly/ActivitySegments")}.count == Int(length/3600),"23/25 DST hours")
        }

        let cloudNow = Date(timeIntervalSinceReferenceDate:1000)
        let cloudGroup = base.appendingPathComponent("cloud-groups")
        let cloudLocal = cloudGroup.appendingPathComponent("fixture/Library/com.apple.DeviceActivity/Local")
        try AppTotalFixtures.create(cloudLocal)
        let cloud = try AppTotalFixtures.cloud(cloudLocal)
        let cloudStore = NativeStorage(database:base.appendingPathComponent("unused"),stream:base.appendingPathComponent("unused"),
            backups:base.appendingPathComponent("cloud-backups"),groupRoot:cloudGroup)
        let cloudDay = cloud.appendingPathComponent("Daily/ActivitySegments/0.0.plist")
        let cloudWeek = cloud.appendingPathComponent("Weekly/ActivitySegments/0.0.plist")
        let cloudDayBytes = try boundedBytes(cloudDay), cloudWeekBytes = try boundedBytes(cloudWeek)
        let localDay = cloudLocal.appendingPathComponent("Daily/ActivitySegments/0.0.plist")
        let localWeek = cloudLocal.appendingPathComponent("Weekly/ActivitySegments/0.0.plist")
        for path in [localDay,localWeek,cloudLocal.appendingPathComponent("Daily/Metadata.plist"),cloudLocal.appendingPathComponent("Weekly/Metadata.plist")] {
            try FileManager.default.removeItem(at:path)
        }
        let cloudPlans = try cloudStore.prepareAppTotals(request,now:cloudNow)
        let dayPlan = cloudPlans.first { $0.path == localDay }!, weeklyPlan = cloudPlans.first { $0.path == localWeek }!
        try check(dayPlan.original == nil && weeklyPlan.original == nil,"missing Local records explicitly planned as creation")
        try check(try total(dayPlan.replacement) == 14400 && total(weeklyPlan.replacement) == 14400,"same-device Cloud day/week exact sum and outside contribution")
        func normalizedCloud(_ data: Data) throws -> Data {
            var doc = NativeAppTotals.withoutRecordIdentity(try PropertyListSerialization.propertyList(from:data,format:nil)) as! [String:Any]
            var value = doc["value"] as! [String:Any]; value["recordZoneName"] = "fixture"; doc["value"] = value
            return try AppTotalFixtures.bytes(doc)
        }
        try assertCategories(normalizedCloud(cloudDayBytes),dayPlan.replacement)
        try assertCategories(normalizedCloud(cloudWeekBytes),weeklyPlan.replacement)
        let cloudOldApps = try NativeAppTotals.apps(NativeAppTotals.SegmentValue(cloudWeekBytes).value)
        let cloudOldDay = try NativeAppTotals.apps(NativeAppTotals.SegmentValue(cloudDayBytes).value)
        let cloudNewApps = try NativeAppTotals.apps(NativeAppTotals.SegmentValue(weeklyPlan.replacement).value)
        for bundle in [AppTotalFixtures.a,AppTotalFixtures.b] {
            try check(cloudNewApps[bundle]!.duration-7200 == cloudOldApps[bundle]!.duration-cloudOldDay[bundle]!.duration,"Cloud per-app outside-week contribution exact")
        }
        try check(try boundedBytes(cloudDay) == cloudDayBytes && boundedBytes(cloudWeek) == cloudWeekBytes &&
            !FileManager.default.fileExists(atPath:localDay.path),"Cloud fallback planning read-only; never edits Cloud")
        try check(!FileManager.default.fileExists(atPath:cloudStore.backups.path),"planning does not create backup")
        let metaPath = cloud.appendingPathComponent("Daily/Metadata.plist")
        let savedMeta = try boundedBytes(metaPath)
        func changedMeta(_ edit: (inout [String:Any]) -> Void) throws -> Data {
            var doc = try PropertyListSerialization.propertyList(from:savedMeta,format:nil) as! [String:Any]
            var value = doc["value"] as! [String:Any]; edit(&value); doc["value"] = value
            return try AppTotalFixtures.bytes(doc)
        }
        for (label,data) in [
            ("stale",try changedMeta { $0["lastUpdatedDate"] = Date(timeIntervalSinceReferenceDate:-120) }),
            ("future",try changedMeta { $0["lastUpdatedDate"] = now.addingTimeInterval(86400) }),
            ("wrong device",try changedMeta { $0["device"] = ["identifier":"other"] }),
            ("wrong user",try changedMeta { $0["user"] = ["role":1] }),
            ("wrong record",try changedMeta { $0["recordName"] = "other_Daily" }),
            ("wrong interval",try changedMeta { $0["segmentInterval"] = 0 }),
            ("unknown schema",try changedMeta { $0["unknownProvenance"] = 1 }),
            ("missing identity",try changedMeta { $0.removeValue(forKey:"recordSystemFields") }),
            ("malformed identity",try changedMeta { $0["recordSystemFields"] = Data([1,2,3]) })
        ] {
            try cloudStore.writeExisting(metaPath,original:boundedBytes(metaPath),replacement:data)
            try rejects("Cloud "+label+" fails closed") { _ = try cloudStore.prepareAppTotals(request,now:cloudNow) }
        }
        try cloudStore.writeExisting(metaPath,original:boundedBytes(metaPath),replacement:savedMeta)
        let noCoverage = ApplyRequest(start:-86400,end:0,sessions:[],revision:rev)
        try rejects("uncovered earlier day fails independently") { _ = try cloudStore.prepareAppTotals(noCoverage,now:cloudNow) }
        try check(try cloudStore.prepareAppTotals(request,now:cloudNow).count == 29,"earlier unknown does not block covered day")
        // A copied record from another granularity/zone cannot impersonate this device/day.
        try cloudStore.writeExisting(cloudDay,original:cloudDayBytes,replacement:cloudWeekBytes)
        try rejects("mismatched day/week Cloud record rejected") { _ = try cloudStore.prepareAppTotals(request,now:cloudNow) }
        try cloudStore.writeExisting(cloudDay,original:cloudWeekBytes,replacement:cloudDayBytes)
        let second = cloud.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("second-account/"+cloud.lastPathComponent)
        try FileManager.default.createDirectory(at:second,withIntermediateDirectories:true)
        try rejects("ambiguous cross-account device directory rejected") { _ = try cloudStore.prepareAppTotals(request,now:cloudNow) }
        try FileManager.default.removeItem(at:second.deletingLastPathComponent())
        // Existing native week wins over Cloud; no replaced or zeroed outside history.
        let savedLocalWeek = try AppTotalFixtures.bytes(AppTotalFixtures.document(start:0,duration:604800,a:900,b:800))
        try privateWrite(savedLocalWeek,localWeek)
        try privateWrite(try boundedBytes(cloudLocal.appendingPathComponent("Hourly/Metadata.plist")),cloudLocal.appendingPathComponent("Weekly/Metadata.plist"))
        let preserved = try cloudStore.prepareAppTotals(request,now:cloudNow)
        try check(try total(preserved.first { $0.path == localWeek }!.replacement) == 15900,"known Local weekly outside history takes precedence")
        try check(try boundedBytes(localWeek) == savedLocalWeek,"known Local weekly read-only while planning")
        try FileManager.default.removeItem(at:localWeek)
        try FileManager.default.removeItem(at:cloudLocal.appendingPathComponent("Weekly/Metadata.plist"))
        for plan in cloudPlans { try cloudStore.writeAppTotal(plan) } // fixture only
        try check(try cloudStore.prepareAppTotals(request,now:cloudNow).count == 29,"promoted native Cloud records reusable without legacy rejection")
        try check(try boundedBytes(cloudDay) == cloudDayBytes && boundedBytes(cloudWeek) == cloudWeekBytes,"fixture writes leave Cloud sources unchanged")

        let outsideGroup = base.appendingPathComponent("cloud-outside")
        let outsideLocal = outsideGroup.appendingPathComponent("fixture/Library/com.apple.DeviceActivity/Local")
        try AppTotalFixtures.create(outsideLocal)
        let outsideCloud = try AppTotalFixtures.cloud(outsideLocal,today:86400)
        for relative in ["Weekly/ActivitySegments/0.0.plist","Daily/Metadata.plist","Weekly/Metadata.plist"] {
            try FileManager.default.removeItem(at:outsideLocal.appendingPathComponent(relative))
        }
        let outsideStore = NativeStorage(database:base.appendingPathComponent("unused"),stream:base.appendingPathComponent("unused"),
            backups:base.appendingPathComponent("unused"),groupRoot:outsideGroup)
        let outsideRequest = ApplyRequest(start:86400,end:172800,sessions:[
            StoredSession(bundle:AppTotalFixtures.a,start:90000,end:131400),
            StoredSession(bundle:AppTotalFixtures.b,start:90000,end:131400)],revision:rev)
        let outsideNow = Date(timeIntervalSinceReferenceDate:90000)
        let covered = try outsideStore.prepareAppTotals(outsideRequest,now:outsideNow)
        try check(try total(covered.first { $0.path.path.contains("/Daily/ActivitySegments/") }!.replacement) == 82800,"covered next-day production plan exact 23h")
        try check(try total(covered.first { $0.path.path.contains("/Weekly/ActivitySegments/") }!.replacement) == 83000,"Cloud prior-day native 200 seconds preserved exactly")
        let priorDay = outsideCloud.appendingPathComponent("Daily/ActivitySegments/0.0.plist")
        let priorBytes = try boundedBytes(priorDay)
        try FileManager.default.removeItem(at:priorDay)
        try rejects("missing outside prior day never assumed zero") { _ = try outsideStore.prepareAppTotals(outsideRequest,now:outsideNow) }
        try privateWrite(priorBytes,priorDay)
        let outsideWeek = outsideCloud.appendingPathComponent("Weekly/ActivitySegments/0.0.plist")
        let outsideWeekBytes = try boundedBytes(outsideWeek)
        var weekDoc = try PropertyListSerialization.propertyList(from:outsideWeekBytes,format:nil) as! [String:Any]
        var weekValue = weekDoc["value"] as! [String:Any]
        var weekCategories = weekValue["categoryActivities"] as! [[String:Any]]
        var weekApps = weekCategories[0]["applicationActivities"] as! [[String:Any]]
        weekApps[0]["totalActivityDuration"] = 201.0
        weekCategories[0]["applicationActivities"] = weekApps
        weekValue["categoryActivities"] = weekCategories; weekDoc["value"] = weekValue
        try outsideStore.writeExisting(outsideWeek,original:outsideWeekBytes,replacement:AppTotalFixtures.bytes(weekDoc))
        try rejects("unknown future or uncovered weekly contribution rejected") { _ = try outsideStore.prepareAppTotals(outsideRequest,now:outsideNow) }
        try outsideStore.writeExisting(outsideWeek,original:boundedBytes(outsideWeek),replacement:outsideWeekBytes)
        let outsideMeta = outsideCloud.appendingPathComponent("Daily/Metadata.plist")
        let outsideMetaBytes = try boundedBytes(outsideMeta)
        var oldDoc = try PropertyListSerialization.propertyList(from:outsideMetaBytes,format:nil) as! [String:Any]
        var oldValue = oldDoc["value"] as! [String:Any]
        oldValue["lastUpdatedDate"] = Date(timeIntervalSinceReferenceDate:0);oldDoc["value"] = oldValue
        try outsideStore.writeExisting(outsideMeta,original:outsideMetaBytes,replacement:AppTotalFixtures.bytes(oldDoc))
        try rejects("stale Cloud snapshot before selected today rejected") { _ = try outsideStore.prepareAppTotals(outsideRequest,now:outsideNow) }
        try outsideStore.writeExisting(outsideMeta,original:boundedBytes(outsideMeta),replacement:outsideMetaBytes)
        // Local Hourly has its own refresh cycle; it is not a history bound.
        let laterHourMeta = outsideLocal.appendingPathComponent("Hourly/Metadata.plist")
        let hourBefore = try boundedBytes(laterHourMeta)
        var hourDoc = try PropertyListSerialization.propertyList(from:hourBefore,format:nil) as! [String:Any]
        var hourValue = hourDoc["value"] as! [String:Any]
        hourValue["lastUpdatedDate"] = Date(timeIntervalSinceReferenceDate:89999);hourDoc["value"] = hourValue
        try outsideStore.writeExisting(laterHourMeta,original:hourBefore,replacement:AppTotalFixtures.bytes(hourDoc))
        try check(try outsideStore.prepareAppTotals(outsideRequest,now:outsideNow).count == 29,
            "coherent fully covered Cloud snapshot survives independently newer Local Hourly")
        print("PASS native summed-category production planner \(count) checks; disposable fixtures only, no planning bypass")
    }
}
