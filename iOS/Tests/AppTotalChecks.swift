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
            try check(try bytes(x) == bytes(y), "native category aggregate and all unrelated category fields byte-identical")
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
        let keepB = try NativeAppTotals.replacing(parsed,totals:[AppTotalFixtures.a:7200,AppTotalFixtures.b:100],catalog:catalog)
        let oldCats = parsed.value["categoryActivities"] as! [[String:Any]]
        let newCats = try NativeAppTotals.SegmentValue(keepB).value["categoryActivities"] as! [[String:Any]]
        try check(try bytes(oldCats[1]) == bytes(newCats[1]),"unaffected category entirely byte-identical")
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
        print("PASS native preserve-category production planner \(count) checks; disposable fixtures only, no planning bypass")
    }
}
