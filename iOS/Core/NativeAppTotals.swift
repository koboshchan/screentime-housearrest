import Foundation
import CoreFoundation
import CloudKit
import Darwin

/// Native adaptation of the Gemini DeviceActivity cache bypass. Never imports
/// proof data or synthesizes sample usage: durations come only from Apply.
enum NativeAppTotals {
    struct SegmentValue {
        var document: [String: Any]
        var value: [String: Any]
        let start: Double
        let end: Double
        init(_ data: Data) throws {
            guard let doc = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let val = doc["value"] as? [String: Any],
                  let interval = val["dateInterval"] as? [String: Any],
                  let start = interval["start"] as? Date else {
                throw StorageFailure("unsupported_schema", "Unsupported DeviceActivity segment.")
            }
            let duration = try NativeAppTotals.seconds(interval["duration"])
            try requireStorage(duration > 0 && duration <= 8 * 86400 && start.timeIntervalSinceReferenceDate.isFinite,
                               "Invalid DeviceActivity interval.", "unsupported_schema")
            document = doc; value = val
            self.start = start.timeIntervalSinceReferenceDate; end = self.start + duration
            _ = try NativeAppTotals.apps(val)
        }
    }
    struct App {
        let category: [String: Any]
        let value: [String: Any]
        let duration: Double
    }
    static func seconds(_ input: Any?) throws -> Double {
        guard let n = input as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0 else {
            throw StorageFailure("unsupported_schema", "Invalid DeviceActivity app duration.")
        }
        return n.doubleValue
    }
    static func apps(_ value: [String: Any]) throws -> [String: App] {
        guard let categories = value["categoryActivities"] as? [[String: Any]] else {
            throw StorageFailure("unsupported_schema", "Missing DeviceActivity categories.")
        }
        var result: [String: App] = [:], ids = Set<String>()
        for category in categories {
            guard let id = category["identifier"] as? String, !id.isEmpty,
                  let entries = category["applicationActivities"] as? [[String: Any]],
                  category["webDomainActivities"] is [[String: Any]] else {
                throw StorageFailure("unsupported_schema", "Unsupported DeviceActivity category.")
            }
            try requireStorage(ids.insert(id).inserted, "Duplicate DeviceActivity category.", "unsupported_schema")
            for entry in entries {
                guard let bundle = entry["bundleIdentifier"] as? String, SessionRules.isValidBundleID(bundle) else {
                    throw StorageFailure("unsupported_schema", "Invalid DeviceActivity app identifier.")
                }
                try requireStorage(result[bundle] == nil, "Duplicate DeviceActivity app; refusing double count.", "unsupported_schema")
                result[bundle] = App(category: category, value: entry, duration: try seconds(entry["totalActivityDuration"]))
            }
        }
        return result
    }
    static func durations(_ request: ApplyRequest, start: Double, end: Double) -> [String: Double] {
        var result: [String: Double] = [:]
        for session in request.sessions {
            let amount = max(0, min(end, session.end) - max(start, session.start))
            if amount > 0 { result[session.bundle, default: 0] += amount }
        }
        return result
    }
    /// Category/web aggregates and old segment totals are deliberately NOT inputs
    /// to the sum. Web entries remain intact, but contribute no additional time.
    static func replacing(_ segment: SegmentValue, totals: [String: Double], catalog: [String: App]) throws -> Data {
        var value = segment.value
        var categories = value["categoryActivities"] as! [[String: Any]]
        var present = Set<String>()
        for i in categories.indices {
            var entries = categories[i]["applicationActivities"] as! [[String: Any]]
            for j in entries.indices {
                let bundle = entries[j]["bundleIdentifier"] as! String
                let amount = try seconds(totals[bundle] ?? 0)
                if try seconds(entries[j]["totalActivityDuration"]) != amount {
                    entries[j]["totalActivityDuration"] = amount
                }
                present.insert(bundle)
            }
            categories[i]["applicationActivities"] = entries
        }
        for bundle in totals.keys.sorted() where !present.contains(bundle) {
            let amount = try seconds(totals[bundle])
            guard amount > 0 else { continue }
            guard let template = catalog[bundle], let id = template.category["identifier"] as? String else {
                throw StorageFailure("unsupported_schema", "No trusted native app/category template for \(bundle); nothing applied.")
            }
            var entry = template.value
            entry["totalActivityDuration"] = amount
            entry["numberOfPickups"] = 0; entry["numberOfNotifications"] = 0
            if let index = categories.firstIndex(where: { $0["identifier"] as? String == id }) {
                var entries = categories[index]["applicationActivities"] as! [[String: Any]]
                entries.append(entry); categories[index]["applicationActivities"] = entries
            } else {
                var category = template.category
                category["applicationActivities"] = [entry]; category["webDomainActivities"] = [[String: Any]]()
                categories.append(category)
            }
        }
        // Keep every displayed aggregate on the same apps-only policy. Native
        // web payloads remain intact, but are not added a second time.
        for i in categories.indices {
            let entries = categories[i]["applicationActivities"] as! [[String: Any]]
            let amount = try entries.reduce(0.0) { try $0 + seconds($1["totalActivityDuration"]) }
            try requireStorage(amount.isFinite, "DeviceActivity category sum overflow.", "invalid_input")
            categories[i]["totalActivityDuration"] = amount
        }
        var sum = 0.0
        for amount in totals.values { sum += try seconds(amount) }
        try requireStorage(sum.isFinite, "DeviceActivity sum overflow.", "invalid_input")
        value["categoryActivities"] = categories
        value["totalActivityDuration"] = sum
        var document = segment.document; document["value"] = value
        return try PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0)
    }
    /// Native Local Daily/Hourly/Weekly values have the same verified schema.
    /// A cloned record must not retain another CloudKit record's system identity.
    static func withoutRecordIdentity(_ input: Any) -> Any {
        if let dict = input as? [String: Any] {
            return dict.filter { !["recordSystemFields", "recordName", "recordID"].contains($0.key) }
                .mapValues { withoutRecordIdentity($0) }
        }
        if let array = input as? [Any] { return array.map { withoutRecordIdentity($0) } }
        return input
    }
    static func blank(_ source: SegmentValue, start: Double, duration: Double) throws -> SegmentValue {
        let keys: Set<String> = ["recordZoneName", "recordSystemFields", "dateInterval", "categoryActivities",
            "firstPickup", "longestActivity", "totalActivityDuration", "totalPickupsWithoutApplicationActivity"]
        try requireStorage(Set(source.document.keys) == ["value"] && Set(source.value.keys).isSubset(of: keys),
                           "Unknown native cache schema; cannot synthesize a segment.", "unsupported_schema")
        var document = withoutRecordIdentity(source.document) as! [String: Any]
        var value = document["value"] as! [String: Any]
        value["dateInterval"] = ["start": Date(timeIntervalSinceReferenceDate: start), "duration": duration]
        value.removeValue(forKey: "firstPickup"); value.removeValue(forKey: "longestActivity")
        value["totalPickupsWithoutApplicationActivity"] = 0
        value["totalActivityDuration"] = 0.0
        value["categoryActivities"] = [[String: Any]]()
        document["value"] = value
        return try SegmentValue(PropertyListSerialization.data(fromPropertyList: document, format: .binary, options: 0))
    }
    static func synthesized(_ segment: SegmentValue, totals: [String: Double], catalog: [String: App]) throws -> Data {
        let data = try replacing(segment, totals: totals, catalog: catalog)
        let document = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try PropertyListSerialization.data(fromPropertyList: withoutRecordIdentity(document), format: .binary, options: 0)
    }
    /// Verified native Local metadata uses enum 0/1/2 for Hourly/Daily/Weekly
    /// and the SAME device record prefix, suffixed with the granularity.
    /// Values are derived only from THIS device's Hourly metadata.
    static func synthesizedMetadata(_ data: Data, granularity: String, until: Date) throws -> Data {
        guard let doc = try PropertyListSerialization.propertyList(from:data,format:nil) as? [String:Any],
              Set(doc.keys) == ["value"], var value = doc["value"] as? [String:Any],
              Set(value.keys).isSubset(of:["device","user","lastUpdatedDate","recordName","recordSystemFields","segmentInterval"]),
              let device = value["device"] as? [String:Any], !device.isEmpty,
              let user = value["user"] as? [String:Any], !user.isEmpty,
              let interval = value["segmentInterval"] as? NSNumber, CFGetTypeID(interval) != CFBooleanGetTypeID(),
              interval.intValue == 0 && interval.doubleValue == 0,
              let record = value["recordName"] as? String, record.hasSuffix("_Hourly"),
              UUID(uuidString:String(record.dropLast("_Hourly".count))) != nil,
              value["lastUpdatedDate"] is Date, ["Daily","Weekly"].contains(granularity) else {
            throw StorageFailure("unsupported_schema","Unverified native metadata schema; nothing applied.")
        }
        value.removeValue(forKey:"recordSystemFields")
        value["recordName"] = String(record.dropLast("_Hourly".count)) + "_" + granularity
        value["segmentInterval"] = granularity == "Daily" ? 1 : 2
        return try metadata(PropertyListSerialization.data(fromPropertyList:["value":value],format:.binary,options:0),until:until)
    }
    /// Decode only Apple's secure system-field archive, never arbitrary classes.
    /// Both zone and record names must bind a segment to this device/granularity.
    static func cloudIdentity(_ value: [String: Any], name: String, zone: String, type: String) throws {
        guard let data = value["recordSystemFields"] as? Data, !data.isEmpty, data.count <= 1024*1024 else {
            throw StorageFailure("untrusted_baseline", "Cloud record identity is missing; nothing applied.")
        }
        let coder = try NSKeyedUnarchiver(forReadingFrom:data)
        coder.requiresSecureCoding = true
        coder.decodingFailurePolicy = .setErrorAndReturn
        let record = CKRecord(coder:coder)
        coder.finishDecoding()
        try requireStorage(coder.error == nil && record?.recordType == type &&
            record?.recordID.recordName == name && record?.recordID.zoneID.zoneName == zone,
            "Cloud record device, interval or zone identity mismatch; nothing applied.", "untrusted_baseline")
    }
    static func metadata(_ data: Data, until: Date) throws -> Data {
        guard var doc = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var value = doc["value"] as? [String: Any],
              let old = value["lastUpdatedDate"] as? Date,
              old.timeIntervalSinceReferenceDate.isFinite, until.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageFailure("unsupported_schema", "Unsupported DeviceActivity refresh metadata.")
        }
        // Native DeviceActivity constructs a fetch interval from this watermark to now.
        // A future watermark traps DateInterval(start:end:) in Settings.
        value["lastUpdatedDate"] = until
        doc["value"] = value
        return try PropertyListSerialization.data(fromPropertyList: doc, format: .binary, options: 0)
    }
}

struct NativeCacheWrite {
    let path: URL
    let original: Data?  // nil for an explicitly backed-up absent cache path
    let replacement: Data
    let template: URL
}

extension NativeStorage {
    /// Use native on-disk week/time-zone settings, never an assumed Monday or
    /// a fixed seven-day seconds count. DST can shorten/lengthen the week.
    func cacheCalendar(_ root: URL) throws -> Calendar {
        let parent = root.deletingLastPathComponent()
        func value(_ name: String) throws -> Any? {
            let doc = try PropertyListSerialization.propertyList(from:boundedBytes(parent.appendingPathComponent(name)),format:nil) as? [String:Any]
            return doc?["value"]
        }
        guard let first = try value("LocalFirstWeekday.plist") as? NSNumber,
              CFGetTypeID(first) != CFBooleanGetTypeID(), first.doubleValue == Double(first.intValue),
              (1...7).contains(first.intValue),
              let zoneValue = try value("LocalTimeZone.plist") as? [String:Any],
              let identifier = zoneValue["identifier"] as? String,
              let zone = TimeZone(identifier:identifier) else {
            throw StorageFailure("unsupported_schema","Missing or invalid native calendar metadata.")
        }
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = zone; calendar.firstWeekday = first.intValue
        calendar.minimumDaysInFirstWeek = 1
        return calendar
    }
    /// Resolve only this device's Cloud directory under exactly one account.
    /// Never scan another device for substitute usage or infer empty history.
    func sameDeviceCloudRoot(_ root: URL) throws -> URL? {
        let parent = root.deletingLastPathComponent()
        let identifierPath = parent.appendingPathComponent("LocalDeviceIdentifier.plist")
        try rejectLinks(identifierPath)
        var info = stat()
        if lstat(identifierPath.path,&info) != 0 {
            try requireStorage(errno == ENOENT,"Cannot inspect local device identity.","read_failed")
            return nil
        }
        let doc = try PropertyListSerialization.propertyList(from:boundedBytes(identifierPath),format:nil) as? [String:Any]
        guard let identifier = doc?["value"] as? String, UUID(uuidString:identifier) != nil else {
            throw StorageFailure("untrusted_baseline","Invalid local device identity; nothing applied.")
        }
        let cloud = parent.appendingPathComponent("Cloud")
        try rejectLinks(cloud)
        if lstat(cloud.path,&info) != 0 {
            try requireStorage(errno == ENOENT,"Cannot inspect Cloud root.","read_failed")
            return nil
        }
        try requireStorage(info.st_mode & S_IFMT == S_IFDIR,"Unsafe Cloud root.","unsafe_path")
        let accounts = try FileManager.default.contentsOfDirectory(at:cloud,includingPropertiesForKeys:nil)
        try requireStorage(accounts.count <= 1000,"Too many Cloud accounts.","size_limit")
        var matches: [URL] = []
        for account in accounts {
            try rejectLinks(account)
            try requireStorage(lstat(account.path,&info) == 0,"Cannot inspect Cloud account entry.","read_failed")
            if info.st_mode & S_IFMT == S_IFREG && info.st_nlink == 1 { continue }
            try requireStorage(info.st_mode & S_IFMT == S_IFDIR,"Unsafe Cloud account directory.","unsafe_path")
            let device = account.appendingPathComponent(identifier)
            try rejectLinks(device)
            if lstat(device.path,&info) == 0 {
                try requireStorage(info.st_mode & S_IFMT == S_IFDIR,"Unsafe Cloud device directory.","unsafe_path")
                matches.append(device)
            } else { try requireStorage(errno == ENOENT,"Cannot inspect Cloud device.","read_failed") }
        }
        try requireStorage(matches.count <= 1,"Ambiguous same-device Cloud accounts.","untrusted_baseline")
        return matches.first
    }

    /// Bootstrap is deliberately limited to an existing, entirely empty Local
    /// layout. A partial cache is not permission to replace native provenance.
    func cloudOnlyLayout(_ root: URL) throws -> Bool {
        var empty = true
        for granularity in ["Hourly","Daily","Weekly"] {
            let directory = root.appendingPathComponent(granularity+"/ActivitySegments")
            try rejectLinks(directory)
            var info = stat()
            try requireStorage(lstat(directory.path,&info) == 0 && info.st_mode & S_IFMT == S_IFDIR,
                "Native cache directories must already exist; nothing applied.","cache_not_ready")
            if !(try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)).isEmpty { empty = false }
            let metadata = root.appendingPathComponent(granularity+"/Metadata.plist")
            try rejectLinks(metadata)
            if lstat(metadata.path,&info) == 0 { empty = false }
            else { try requireStorage(errno == ENOENT,"Cannot inspect cache metadata.","read_failed") }
        }
        return empty
    }

    func cloudBaseline(_ root: URL, granularity: String, start: Double, end: Double,
                       now: Date) throws -> NativeAppTotals.SegmentValue {
        guard let cloud = try sameDeviceCloudRoot(root) else {
            throw StorageFailure("incomplete_baseline","No matching same-device native Cloud baseline; nothing applied.")
        }
        let identifier = cloud.lastPathComponent
        func metadataValue(_ path: URL) throws -> [String:Any] {
            guard let doc = try PropertyListSerialization.propertyList(from:boundedBytes(path),format:nil) as? [String:Any],
                  let value = doc["value"] as? [String:Any] else {
                throw StorageFailure("untrusted_baseline","Invalid Cloud provenance metadata; nothing applied.")
            }
            return value
        }
        let bootstrap = try cloudOnlyLayout(root)
        let hourly = try metadataValue((bootstrap ? cloud : root).appendingPathComponent("Hourly/Metadata.plist"))
        let meta = try metadataValue(cloud.appendingPathComponent(granularity+"/Metadata.plist"))
        let expected = identifier+"_"+granularity
        let metadataKeys: Set<String> = ["device","user","lastUpdatedDate","recordName","recordSystemFields","segmentInterval"]
        guard Set(meta.keys).isSubset(of:metadataKeys),
              let device = hourly["device"] as? [String:Any], device["identifier"] as? String == identifier,
              let hourlyInterval = hourly["segmentInterval"] as? NSNumber, CFGetTypeID(hourlyInterval) != CFBooleanGetTypeID(),
              hourlyInterval.doubleValue == 0,
              let user = hourly["user"] as? [String:Any], !user.isEmpty,
              let cloudDevice = meta["device"] as? [String:Any], let cloudUser = meta["user"] as? [String:Any],
              NSDictionary(dictionary:device).isEqual(to:cloudDevice),
              NSDictionary(dictionary:user).isEqual(to:cloudUser),
              hourly["recordName"] as? String == identifier+"_Hourly",
              meta["recordName"] as? String == expected,
              let interval = meta["segmentInterval"] as? NSNumber, CFGetTypeID(interval) != CFBooleanGetTypeID(),
              interval.doubleValue == (granularity == "Hourly" ? 0 : (granularity == "Daily" ? 1 : 2)),
              let localDate = hourly["lastUpdatedDate"] as? Date,
              let cloudDate = meta["lastUpdatedDate"] as? Date,
              localDate.timeIntervalSinceReferenceDate.isFinite, cloudDate.timeIntervalSinceReferenceDate.isFinite,
              cloudDate <= now, localDate <= now,
              cloudDate >= (try cacheCalendar(root)).startOfDay(for:now),
              !bootstrap || (cloudDate == localDate && now.timeIntervalSince(cloudDate) <= 3600),
              cloudDate.timeIntervalSinceReferenceDate >= start else {
            throw StorageFailure("untrusted_baseline","Cloud baseline predates today or does not match local device/user provenance; nothing applied.")
        }
        try NativeAppTotals.cloudIdentity(meta,name:expected,zone:expected,type:"Metadata")
        if bootstrap {
            let deviceKeys: Set<String> = ["identifier","coreDuetIdentifier","name","model"]
            let userKeys: Set<String> = ["altDSID","appleID","nameComponents","role"]
            try requireStorage(Set(hourly.keys) == metadataKeys &&
                Set(device.keys) == deviceKeys && device["coreDuetIdentifier"] is String &&
                device["name"] is String && device["model"] is NSNumber &&
                Set(user.keys) == userKeys && user["altDSID"] is String &&
                user["appleID"] is String && user["nameComponents"] is [String:Any] &&
                user["role"] is NSNumber,"Unknown Cloud Hourly metadata schema.","unsupported_schema")
            try NativeAppTotals.cloudIdentity(hourly,name:identifier+"_Hourly",zone:identifier+"_Hourly",type:"Metadata")
        }
        let path = cloud.appendingPathComponent(granularity+"/ActivitySegments/"+String(format:"%.1f.plist",start))
        let segment = try NativeAppTotals.SegmentValue(boundedBytes(path))
        let segmentKeys: Set<String> = ["recordZoneName","recordSystemFields","dateInterval","categoryActivities",
            "firstPickup","longestActivity","totalActivityDuration","totalPickupsWithoutApplicationActivity"]
        try requireStorage(Set(segment.document.keys) == ["value"] && Set(segment.value.keys).isSubset(of:segmentKeys) &&
            abs(segment.start-start) < 0.001 && abs(segment.end-end) < 0.001 &&
            segment.value["recordZoneName"] as? String == expected,
            "Cloud baseline does not cover the requested native interval; nothing applied.","untrusted_baseline")
        try NativeAppTotals.cloudIdentity(segment.value,name:String(format:"%.1f",start),zone:expected,type:"ActivitySegment")
        var document = NativeAppTotals.withoutRecordIdentity(segment.document) as! [String:Any]
        var value = document["value"] as! [String:Any]
        // CloudKit zone identities are not valid in Local. Keep Local's envelope.
        if bootstrap {
            // Native Local uses the same device/granularity zone name but never
            // carries the Cloud record's secure system identity.
            value["recordZoneName"] = expected
            document["value"] = value
            return try NativeAppTotals.SegmentValue(PropertyListSerialization.data(fromPropertyList:document,format:.binary,options:0))
        }
        let hourPaths = try FileManager.default.contentsOfDirectory(at:root.appendingPathComponent("Hourly/ActivitySegments"),includingPropertiesForKeys:nil)
            .filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
        guard let first = hourPaths.first else { throw StorageFailure("incomplete_baseline","Missing Local envelope.") }
        let local = try NativeAppTotals.SegmentValue(boundedBytes(first))
        value["recordZoneName"] = local.value["recordZoneName"]
        document["value"] = value
        return try NativeAppTotals.SegmentValue(PropertyListSerialization.data(fromPropertyList:document,format:.binary,options:0))
    }

    /// For today's missing baselines, a coherent native Cloud snapshot can be
    /// older than Local Hourly: selected-day usage is replaced, not inherited.
    /// Prove every CLOSED outside day from native Daily records and reconcile
    /// their per-app sum against Weekly. Missing days or unexplained future
    /// contributions are unknown, never zero. No historical-date fallback.
    func validatedCloudSnapshot(_ root: URL, request: ApplyRequest, now: Date)
        throws -> [String:NativeAppTotals.SegmentValue] {
        let calendar = try cacheCalendar(root)
        let today = calendar.startOfDay(for:now)
        guard abs(request.start-today.timeIntervalSinceReferenceDate) < 0.001,
              let day = calendar.dateInterval(of:.day,for:today),
              abs(request.end-day.end.timeIntervalSinceReferenceDate) < 0.001,
              let week = calendar.dateInterval(of:.weekOfYear,for:today),
              let cloud = try sameDeviceCloudRoot(root) else {
            throw StorageFailure("incomplete_baseline","Cloud fallback requires today's fully covered native day and week; nothing applied.")
        }
        func snapshotDate(_ granularity: String) throws -> Date {
            let doc = try PropertyListSerialization.propertyList(from:boundedBytes(cloud.appendingPathComponent(granularity+"/Metadata.plist")),format:nil) as? [String:Any]
            guard let value = doc?["value"] as? [String:Any], let date = value["lastUpdatedDate"] as? Date else {
                throw StorageFailure("untrusted_baseline","Missing Cloud snapshot timestamp.")
            }
            return date
        }
        let dailyDate = try snapshotDate("Daily"), weeklyDate = try snapshotDate("Weekly")
        try requireStorage(dailyDate == weeklyDate,"Cloud Daily and Weekly snapshots are not coherent; nothing applied.","untrusted_baseline")
        let weekly = try cloudBaseline(root,granularity:"Weekly",start:week.start.timeIntervalSinceReferenceDate,
                                       end:week.end.timeIntervalSinceReferenceDate,now:now)
        var sum: [String:Double] = [:], selected: NativeAppTotals.SegmentValue?
        var cursor = week.start
        var days = 0
        while cursor <= today {
            guard let interval = calendar.dateInterval(of:.day,for:cursor) else {
                throw StorageFailure("unsupported_schema","Unsupported Cloud day interval.")
            }
            let value = try cloudBaseline(root,granularity:"Daily",start:interval.start.timeIntervalSinceReferenceDate,
                                          end:interval.end.timeIntervalSinceReferenceDate,now:now)
            for (bundle,app) in try NativeAppTotals.apps(value.value) { sum[bundle,default:0] += app.duration }
            if cursor == today { selected = value }
            cursor = interval.end; days += 1
            try requireStorage(days <= 7,"Unsupported Cloud week coverage.","unsupported_schema")
        }
        let weeklyApps = try NativeAppTotals.apps(weekly.value)
        for bundle in Set(sum.keys).union(weeklyApps.keys) {
            try requireStorage(abs((sum[bundle] ?? 0)-(weeklyApps[bundle]?.duration ?? 0)) < 0.00001,
                "Cloud week contains uncovered or inconsistent app history; nothing applied.","incomplete_baseline")
        }
        guard let selected else { throw StorageFailure("incomplete_baseline","Selected Cloud day is absent.") }
        return ["Daily":selected,"Weekly":weekly]
    }

    /// All cache planning and schema checks happen BEFORE the verified backup.
    /// Missing/ambiguous layouts fail closed rather than falling back to a union.
    func prepareAppTotals(_ request: ApplyRequest, now: Date = Date()) throws -> [NativeCacheWrite] {
        let roots = try cacheRoots()
        try requireStorage(roots.count == 1, "Expected one local DeviceActivity cache. Open Settings Screen Time, then reload.", "unsupported_schema")
        let root = roots[0]
        let bootstrap = try cloudOnlyLayout(root)
        var segments: [String: [(URL, Data, NativeAppTotals.SegmentValue)]] = [:]
        var catalog: [String: NativeAppTotals.App] = [:]
        for granularity in ["Hourly", "Daily", "Weekly"] {
            let directory = root.appendingPathComponent(granularity + "/ActivitySegments")
            try rejectLinks(directory)
            // Sparse Hourly buckets can be created inside the selected day.
            // Daily/Weekly baselines are never synthesized from sparse history.
            var info = stat()
            if lstat(directory.path,&info) != 0 {
                try requireStorage(errno == ENOENT,
                                   "Cannot inspect DeviceActivity cache directory; nothing applied.","read_failed")
                throw StorageFailure("cache_not_ready", "DeviceActivity \(granularity) cache is not generated yet. Open Settings > Screen Time and view both Day and Week, then return to Surface and reload. Nothing applied.")
            }
            try requireStorage(info.st_mode & S_IFMT == S_IFDIR,"Unsupported DeviceActivity directory; nothing applied.","unsafe_path")
            let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
            try requireStorage(bootstrap || granularity != "Hourly" || !paths.isEmpty,
                               "DeviceActivity \(granularity) cache is not generated yet. Open Settings > Screen Time and view both Day and Week, then return to Surface and reload. Nothing applied.","cache_not_ready")
            try requireStorage(paths.count <= 10000,"Too many DeviceActivity cache segments.","size_limit")
            var list: [(URL, Data, NativeAppTotals.SegmentValue)] = []
            for path in paths {
                let old = try boundedBytes(path), segment = try NativeAppTotals.SegmentValue(old)
                guard let stamp = Double(path.deletingPathExtension().lastPathComponent) else {
                    throw StorageFailure("unsupported_schema", "Invalid DeviceActivity filename.")
                }
                try requireStorage(abs(stamp - segment.start) < 0.01, "DeviceActivity filename/interval mismatch.", "unsupported_schema")
                for (bundle, app) in try NativeAppTotals.apps(segment.value) { catalog[bundle] = app }
                list.append((path, old, segment))
            }
            let sorted = list.sorted { $0.2.start < $1.2.start }
            for (a, b) in zip(sorted, sorted.dropFirst()) {
                try requireStorage(a.2.end <= b.2.start + 0.001, "Overlapping DeviceActivity cache intervals.", "unsupported_schema")
            }
            segments[granularity] = list
        }
        let hours = segments["Hourly"] ?? []
        let template: (URL,Data,NativeAppTotals.SegmentValue)
        if let local = hours.first { template = local }
        else if bootstrap, let cloud = try sameDeviceCloudRoot(root) {
            let directory = cloud.appendingPathComponent("Hourly/ActivitySegments")
            try rejectLinks(directory)
            let paths = try FileManager.default.contentsOfDirectory(at:directory,includingPropertiesForKeys:nil)
                .filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
            try requireStorage(!paths.isEmpty && paths.count <= 10000,"Missing native Cloud Hourly template.","incomplete_baseline")
            guard let path = paths.last, let stamp = Double(path.deletingPathExtension().lastPathComponent) else {
                throw StorageFailure("unsupported_schema","Invalid Cloud Hourly filename.")
            }
            let value = try cloudBaseline(root,granularity:"Hourly",start:stamp,end:stamp+3600,now:now)
            try requireStorage(stamp <= now.timeIntervalSinceReferenceDate,"Future Cloud Hourly interval.","untrusted_baseline")
            template = (path,try boundedBytes(path),value)
            for (bundle,app) in try NativeAppTotals.apps(value.value) { catalog[bundle] = app }
        } else {
            throw StorageFailure("unsupported_schema", "Verified Hourly cache template is required; nothing applied.")
        }
        let calendar = try cacheCalendar(root)
        let dayDate = Date(timeIntervalSinceReferenceDate:request.start)
        guard let weekInterval = calendar.dateInterval(of:.weekOfYear,for:dayDate) else {
            throw StorageFailure("invalid_input","Edit must cover exactly one native calendar day.")
        }
        var promoted = Set<URL>()
        var cloudSnapshot: [String:NativeAppTotals.SegmentValue]?
        func baseline(_ granularity: String, start: Double, end: Double) throws -> (URL,Data,NativeAppTotals.SegmentValue) {
            if let existing = segments[granularity]?.first(where: { abs($0.2.start-start) < 0.01 && abs($0.2.end-end) < 0.01 }) {
                return existing
            }
            // Never overwrite a conflicting Local interval using Cloud.
            try requireStorage(!(segments[granularity] ?? []).contains { $0.2.start < end && $0.2.end > start },
                               "Conflicting Local baseline; nothing applied.","untrusted_baseline")
            if granularity == "Daily" {
                let interval = calendar.dateInterval(of:.day,for:dayDate)
                try requireStorage(interval?.start.timeIntervalSinceReferenceDate == start && interval?.end.timeIntervalSinceReferenceDate == end,
                                   "Cloud fallback requires a complete native calendar day.","invalid_input")
            }
            if cloudSnapshot == nil { cloudSnapshot = try validatedCloudSnapshot(root,request:request,now:now) }
            guard let value = cloudSnapshot?[granularity],
                  abs(value.start-start) < 0.001 && abs(value.end-end) < 0.001 else {
                throw StorageFailure("incomplete_baseline","Missing validated Cloud interval; nothing applied.")
            }
            let path = root.appendingPathComponent(granularity+"/ActivitySegments/"+String(format:"%.1f.plist",start))
            let data = try PropertyListSerialization.data(fromPropertyList:value.document,format:.binary,options:0)
            for (bundle,app) in try NativeAppTotals.apps(value.value) { catalog[bundle] = app }
            promoted.insert(path)
            return (path,data,value)
        }
        // Existing native week intervals remain authoritative. Fixtures and
        // native DST weeks need not equal a fixed seven-day seconds count.
        let daily = try baseline("Daily",start:request.start,end:request.end)
        let weekly: (URL,Data,NativeAppTotals.SegmentValue)
        if let existing = segments["Weekly"]?.first(where: { $0.2.start <= request.start && $0.2.end >= request.end }) {
            weekly = existing
        } else {
            weekly = try baseline("Weekly",start:weekInterval.start.timeIntervalSinceReferenceDate,end:weekInterval.end.timeIntervalSinceReferenceDate)
        }
        try rejectPreviouslySynthesized([daily,weekly].filter { !promoted.contains($0.0) },root:root)
        let dayTotals = NativeAppTotals.durations(request, start: request.start, end: request.end)
        let oldDay = try NativeAppTotals.apps(daily.2.value).mapValues { $0.duration }
        var plans = [NativeCacheWrite(path: daily.0, original: promoted.contains(daily.0) ? nil : daily.1,
            replacement: try NativeAppTotals.replacing(daily.2, totals: dayTotals, catalog: catalog), template: promoted.contains(daily.0) ? template.0 : daily.0)]
        var weekTotals = try NativeAppTotals.apps(weekly.2.value).mapValues { $0.duration }
        for bundle in Set(oldDay.keys).union(dayTotals.keys) {
            let outside = (weekTotals[bundle] ?? 0) - (oldDay[bundle] ?? 0)
            try requireStorage(outside >= -0.01 && outside.isFinite,
                "Weekly app cache is inconsistent with selected-day baseline; nothing applied.", "unsupported_schema")
            weekTotals[bundle] = max(0, outside) + (dayTotals[bundle] ?? 0)
        }
        try requireStorage(weekTotals.values.allSatisfy { $0.isFinite && $0 >= 0 },
                           "Weekly app total overflow.", "unsupported_schema")
        plans.append(NativeCacheWrite(path: weekly.0, original: promoted.contains(weekly.0) ? nil : weekly.1,
            replacement: try NativeAppTotals.replacing(weekly.2, totals: weekTotals, catalog: catalog), template: promoted.contains(weekly.0) ? template.0 : weekly.0))
        // DST days are 23/24/25 buckets. No fixed date or hardcoded device ID.
        let count = (request.end - request.start) / 3600
        try requireStorage(count >= 1 && count <= 25 && abs(count.rounded()-count) < 0.0001,
                           "Unsupported hourly day boundary.", "unsupported_schema")
        for index in 0..<Int(count.rounded()) {
            let start = request.start + Double(index) * 3600, end = start + 3600
            let found = hours.first { abs($0.2.start-start) < 0.01 }
            var segment = found?.2 ?? template.2
            if let found {
                try requireStorage(abs(found.2.end-end) < 0.01, "Unsupported hourly cache interval.", "unsupported_schema")
            } else {
                try requireStorage(!hours.contains { $0.2.start < end && $0.2.end > start }, "Conflicting hourly cache interval.", "unsupported_schema")
                segment = try NativeAppTotals.blank(template.2, start: start, duration: 3600)
            }
            let path = found?.0 ?? root.appendingPathComponent("Hourly/ActivitySegments/"+String(format: "%.1f.plist", start))
            plans.append(NativeCacheWrite(path: path, original: found?.1,
                replacement: try found == nil
                    ? NativeAppTotals.synthesized(segment, totals: NativeAppTotals.durations(request, start: start, end: end), catalog: catalog)
                    : NativeAppTotals.replacing(segment, totals: NativeAppTotals.durations(request, start: start, end: end), catalog: catalog),
                template: found?.0 ?? template.0))
        }
        // Keep the native fetch watermark at this write time, never in the future.
        // This also repairs future watermarks left by earlier Surface versions.
        let until = now
        for granularity in ["Hourly", "Daily", "Weekly"] {
            let path = root.appendingPathComponent(granularity + "/Metadata.plist")
            try rejectLinks(path)
            var info = stat()
            if lstat(path.path,&info) == 0 {
                let old = try boundedBytes(path)
                plans.append(NativeCacheWrite(path:path,original:old,
                    replacement:try NativeAppTotals.metadata(old,until:until),template:path))
            } else {
                if bootstrap, errno == ENOENT, let cloud = try sameDeviceCloudRoot(root) {
                    let source = cloud.appendingPathComponent(granularity+"/Metadata.plist")
                    let document = try PropertyListSerialization.propertyList(from:boundedBytes(source),format:nil)
                    let stripped = NativeAppTotals.withoutRecordIdentity(document) as! [String:Any]
                    var value = stripped["value"] as! [String:Any]
                    value["recordName"] = cloud.lastPathComponent+"_"+granularity
                    let data = try PropertyListSerialization.data(fromPropertyList:["value":value],format:.binary,options:0)
                    plans.append(NativeCacheWrite(path:path,original:nil,
                        replacement:try NativeAppTotals.metadata(data,until:until),template:source))
                    continue
                }
                try requireStorage(errno == ENOENT && granularity != "Hourly" &&
                    promoted.contains(where: { $0.path.contains("/"+granularity+"/") }),
                    "Native refresh metadata is missing; nothing applied.","incomplete_baseline")
                let hourly = root.appendingPathComponent("Hourly/Metadata.plist")
                plans.append(NativeCacheWrite(path:path,original:nil,
                    replacement:try NativeAppTotals.synthesizedMetadata(boundedBytes(hourly),granularity:granularity,until:until),
                    template:hourly))
            }
        }
        try requireStorage(Set(plans.map { $0.path.path }).count == plans.count, "Duplicate cache write plan.", "unsupported_schema")
        try requireStorage(plans.allSatisfy { $0.path.path.hasPrefix(root.path+"/") },
                           "Cache plan escaped Local; nothing applied.","unsafe_path")
        return plans  // metadata is last, only after every segment is written
    }

    /// Old releases could create Daily/Weekly from sparse Hourly observations.
    /// An authenticated absence archive plus the exact identity-stripped legacy
    /// output shape is evidence, unlike a future refresh timestamp on its own.
    func rejectPreviouslySynthesized(_ records: [(URL, Data, NativeAppTotals.SegmentValue)], root: URL) throws {
        let records = records.filter {
            $0.2.value["recordSystemFields"] == nil && $0.2.value["firstPickup"] == nil && $0.2.value["longestActivity"] == nil
        }
        if records.isEmpty { return }
        try rejectLinks(backups)
        var info = stat()
        if lstat(backups.path, &info) != 0 {
            try requireStorage(errno == ENOENT, "Cannot inspect backup provenance.", "read_failed")
            return
        }
        let archives = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        try requireStorage(archives.count <= 1000, "Too many backup provenance records.", "size_limit")
        for archive in archives where UUID(uuidString: archive.lastPathComponent) != nil {
            let manifestURL = archive.appendingPathComponent("manifest.json")
            try rejectLinks(manifestURL)
            var status = stat()
            if lstat(manifestURL.path, &status) != 0 {
                try requireStorage(errno == ENOENT, "Cannot inspect backup manifest.", "read_failed")
                continue // An interrupted archive has no committed manifest.
            }
            let manifest = try JSONDecoder().decode(BackupManifest.self, from: boundedBytes(manifestURL, maximum: 16*1024*1024))
            let candidates = records.filter { record in manifest.absent.contains { $0.originalPath == record.0.path } }
            if candidates.isEmpty { continue }
            _ = try verifyBackup(archive.lastPathComponent)
            let sourceFiles = manifest.files.filter { file in
                ["Hourly", "Daily", "Weekly"].contains { file.originalPath.hasPrefix(root.path + "/" + $0 + "/ActivitySegments/") }
            }
            var catalog: [String: NativeAppTotals.App] = [:]
            var templates: [NativeAppTotals.SegmentValue] = []
            let order = ["Hourly", "Daily", "Weekly"]
            let orderedFiles = sourceFiles.sorted { a, b in
                func rank(_ file: BackupFile) -> Int {
                    order.firstIndex { file.originalPath.contains("/" + $0 + "/ActivitySegments/") } ?? 3
                }
                return rank(a) == rank(b) ? a.originalPath < b.originalPath : rank(a) < rank(b)
            }
            for file in orderedFiles {
                let segment = try NativeAppTotals.SegmentValue(boundedBytes(archive.appendingPathComponent(file.name)))
                if file.originalPath.hasPrefix(root.path + "/Hourly/ActivitySegments/") { templates.append(segment) }
                for (bundle, app) in try NativeAppTotals.apps(segment.value) { catalog[bundle] = app }
            }
            for record in candidates {
                let totals = try NativeAppTotals.apps(record.2.value).mapValues { $0.duration }
                guard totals.keys.allSatisfy({ catalog[$0] != nil }) else { continue }
                for template in templates {
                    let blank = try NativeAppTotals.blank(template, start: record.2.start, duration: record.2.end-record.2.start)
                    // Recreate the former app-sum category writer only to identify
                    // its old output. This data is NEVER a write plan.
                    let data = try NativeAppTotals.synthesized(blank, totals: totals, catalog: catalog)
                    var legacy = try NativeAppTotals.SegmentValue(data).document
                    var value = legacy["value"] as! [String: Any]
                    var categories = value["categoryActivities"] as! [[String: Any]]
                    for i in categories.indices {
                        let entries = categories[i]["applicationActivities"] as! [[String: Any]]
                        categories[i]["totalActivityDuration"] = try entries.reduce(0.0) {
                            try $0 + NativeAppTotals.seconds($1["totalActivityDuration"])
                        }
                    }
                    value["categoryActivities"] = categories; legacy["value"] = value
                    if NSDictionary(dictionary: legacy).isEqual(to: record.2.document) {
                        throw StorageFailure("untrusted_baseline", "A verified backup identifies this as a legacy synthesized baseline with unknown history. Regenerate native Day and Week caches before applying. Nothing applied.")
                    }
                }
            }
        }
    }

    func writeAppTotal(_ plan: NativeCacheWrite) throws {
        if let old = plan.original {
            try writeExisting(plan.path, original: old, replacement: plan.replacement)
            return
        }
        // The inventory/revision check binds the entire parent directory before
        // mutation. O_EXCL prevents overwriting a new daemon-created file.
        try rejectLinks(plan.path)
        let (uid, gid, mode) = try metadata(plan.template)
        let fd = open(plan.path.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        try requireStorage(fd >= 0, "Cache appeared or cannot be created.", "concurrent_change")
        defer { close(fd) }
        try requireStorage(fchown(fd, uid, gid) == 0 && fchmod(fd, mode_t(mode)) == 0, "Cannot preserve cache metadata.", "partial_apply_failed")
        try plan.replacement.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = pwrite(fd, bytes.baseAddress!.advanced(by: offset), bytes.count-offset, off_t(offset))
                try requireStorage(n > 0, "Cache write failed.", "partial_apply_failed")
                offset += n
            }
        }
        try requireStorage(fsync(fd) == 0, "Cache sync failed.", "partial_apply_failed")
    }
}
