import Foundation
import CoreFoundation
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
            var sum = 0.0
            for j in entries.indices {
                let bundle = entries[j]["bundleIdentifier"] as! String
                let amount = try seconds(totals[bundle] ?? 0)
                entries[j]["totalActivityDuration"] = amount
                sum += amount; present.insert(bundle)
            }
            categories[i]["applicationActivities"] = entries
            categories[i]["totalActivityDuration"] = sum
        }
        for bundle in totals.keys.sorted() where !present.contains(bundle) {
            let amount = try seconds(totals[bundle])
            guard amount > 0 else { continue }
            guard let template = catalog[bundle], let id = template.category["identifier"] as? String else {
                throw StorageFailure("unsupported_schema", "No native cache app template for \(bundle). Open Screen Time after using this app, then reload.")
            }
            var entry = template.value
            entry["totalActivityDuration"] = amount
            entry["numberOfPickups"] = 0; entry["numberOfNotifications"] = 0
            if let index = categories.firstIndex(where: { $0["identifier"] as? String == id }) {
                var entries = categories[index]["applicationActivities"] as! [[String: Any]]
                entries.append(entry); categories[index]["applicationActivities"] = entries
                categories[index]["totalActivityDuration"] = try seconds(categories[index]["totalActivityDuration"]) + amount
            } else {
                var category = template.category
                category["applicationActivities"] = [entry]; category["webDomainActivities"] = [[String: Any]]()
                category["totalActivityDuration"] = amount
                categories.append(category)
            }
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
    static func metadata(_ data: Data, until: Date) throws -> Data {
        guard var doc = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              var value = doc["value"] as? [String: Any],
              let old = value["lastUpdatedDate"] as? Date,
              old.timeIntervalSinceReferenceDate.isFinite, until.timeIntervalSinceReferenceDate.isFinite else {
            throw StorageFailure("unsupported_schema", "Unsupported DeviceActivity refresh metadata.")
        }
        value["lastUpdatedDate"] = max(old, until)
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
    /// All cache planning and schema checks happen BEFORE the verified backup.
    /// Missing/ambiguous layouts fail closed rather than falling back to a union.
    func prepareAppTotals(_ request: ApplyRequest, now: Date = Date()) throws -> [NativeCacheWrite] {
        let roots = try cacheRoots()
        try requireStorage(roots.count == 1, "Expected one local DeviceActivity cache. Open Settings Screen Time, then reload.", "unsupported_schema")
        let root = roots[0]
        var segments: [String: [(URL, Data, NativeAppTotals.SegmentValue)]] = [:]
        var catalog: [String: NativeAppTotals.App] = [:]
        for granularity in ["Hourly", "Daily", "Weekly"] {
            let directory = root.appendingPathComponent(granularity + "/ActivitySegments")
            try rejectLinks(directory)
            // Missing Daily/Weekly records and metadata are synthesized only
            // inside existing native directories. Never create arbitrary trees.
            var info = stat()
            if lstat(directory.path,&info) != 0 {
                try requireStorage(errno == ENOENT,
                                   "Cannot inspect DeviceActivity cache directory; nothing applied.","read_failed")
                throw StorageFailure("cache_not_ready", "DeviceActivity \(granularity) cache is not generated yet. Open Settings > Screen Time and view both Day and Week, then return to Surface and reload. Nothing applied.")
            }
            try requireStorage(info.st_mode & S_IFMT == S_IFDIR,"Unsupported DeviceActivity directory; nothing applied.","unsafe_path")
            let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
            try requireStorage(granularity != "Hourly" || !paths.isEmpty,
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
        guard let hours = segments["Hourly"], let template = hours.first else {
            throw StorageFailure("unsupported_schema", "Verified Hourly cache template is required; nothing applied.")
        }
        let weekly = segments["Weekly"]?.first(where: { $0.2.start <= request.start && $0.2.end >= request.end })
        let daily = segments["Daily"]?.first(where: { abs($0.2.start-request.start) < 0.01 && abs($0.2.end-request.end) < 0.01 })
        let dayTotals = NativeAppTotals.durations(request, start: request.start, end: request.end)
        var oldDay: [String: Double]
        var dailySegment: NativeAppTotals.SegmentValue
        if let daily {
            oldDay = try NativeAppTotals.apps(daily.2.value).mapValues { $0.duration }
            dailySegment = daily.2
        } else {
            // The hourly files are sparse native observations, not replacement
            // sessions. Their exact per-app sum is the OLD selected-day baseline.
            // Never subtract the new requested totals or a whole Weekly record.
            try requireStorage(!segments["Daily", default: []].contains { $0.2.start < request.end && $0.2.end > request.start },
                               "Conflicting Daily cache interval.", "unsupported_schema")
            oldDay = [:]
            let selected = hours.filter { $0.2.start < request.end && $0.2.end > request.start }
            try requireStorage(!selected.isEmpty, "No observed hourly baseline for missing Daily cache.", "unsupported_schema")
            for hour in selected {
                let offset = (hour.2.start-request.start)/3600
                try requireStorage(hour.2.start >= request.start && hour.2.end <= request.end &&
                    abs(hour.2.end-hour.2.start-3600) < 0.001 && abs(offset.rounded()-offset) < 0.000001,
                    "Unsafe hourly baseline for missing Daily cache.", "unsupported_schema")
                for (bundle, app) in try NativeAppTotals.apps(hour.2.value) {
                    oldDay[bundle, default: 0] += app.duration
                    try requireStorage(oldDay[bundle]!.isFinite, "Hourly baseline overflow.", "unsupported_schema")
                }
            }
            // Verify both cross-granularity templates before cloning the value.
            _ = try NativeAppTotals.blank(template.2, start: request.start, duration: request.end-request.start)
            dailySegment = try NativeAppTotals.blank(weekly?.2 ?? template.2, start: request.start, duration: request.end-request.start)
        }
        let dailyPath = daily?.0 ?? root.appendingPathComponent("Daily/ActivitySegments/")
            .appendingPathComponent(String(format: "%.1f.plist", request.start))
        var plans = [NativeCacheWrite(path: dailyPath, original: daily?.1,
            replacement: try daily == nil
                ? NativeAppTotals.synthesized(dailySegment, totals: dayTotals, catalog: catalog)
                : NativeAppTotals.replacing(dailySegment, totals: dayTotals, catalog: catalog),
            template: daily?.0 ?? template.0)]
        var weekTotals: [String:Double]
        var weeklySegment: NativeAppTotals.SegmentValue
        var weeklyPath: URL
        if let weekly {
            weeklySegment = weekly.2; weeklyPath = weekly.0
            weekTotals = try NativeAppTotals.apps(weekly.2.value).mapValues { $0.duration }
            for bundle in Set(oldDay.keys).union(dayTotals.keys) {
                let outside = (weekTotals[bundle] ?? 0) - (oldDay[bundle] ?? 0)
                try requireStorage(outside >= -0.01 && outside.isFinite,
                                   "Weekly app cache is inconsistent with selected-day baseline; nothing applied.", "unsupported_schema")
                weekTotals[bundle] = max(0,outside) + (dayTotals[bundle] ?? 0)
            }
        } else {
            let calendar = try cacheCalendar(root)
            let selectedDate = Date(timeIntervalSinceReferenceDate:request.start)
            try requireStorage(calendar.startOfDay(for:selectedDate) == selectedDate &&
                calendar.date(byAdding:.day,value:1,to:selectedDate)?.timeIntervalSinceReferenceDate == request.end,
                "Edit does not match native local day.", "unsupported_schema")
            guard let interval = calendar.dateInterval(of:.weekOfYear,for:selectedDate) else {
                throw StorageFailure("unsupported_schema","Cannot resolve native week boundary.")
            }
            let lo = interval.start.timeIntervalSinceReferenceDate, hi = interval.end.timeIntervalSinceReferenceDate
            try requireStorage(lo <= request.start && hi >= request.end &&
                !segments["Weekly",default:[]].contains { $0.2.start < hi && $0.2.end > lo },
                "Conflicting Weekly cache interval.", "unsupported_schema")
            weeklySegment = try NativeAppTotals.blank(template.2,start:lo,duration:hi-lo)
            weeklyPath = root.appendingPathComponent("Weekly/ActivitySegments/")
                .appendingPathComponent(String(format:"%.1f.plist",lo))
            // Preserve EVERY observed outside-day app duration. Prefer a native
            // Daily baseline where present, otherwise sum its non-overlapping
            // Hourly observations. Missing observations are not invented usage.
            // Never double-count the same day's Daily + Hourly cache.
            weekTotals = dayTotals
            var cursor = interval.start
            while cursor < interval.end {
                guard let next = calendar.date(byAdding:.day,value:1,to:cursor) else {
                    throw StorageFailure("unsupported_schema","Invalid native week day.")
                }
                let start = cursor.timeIntervalSinceReferenceDate, end = next.timeIntervalSinceReferenceDate
                if abs(start-request.start) >= 0.01 {
                    let dayRecords = segments["Daily",default:[]].filter { $0.2.start < end && $0.2.end > start }
                    let hourRecords = hours.filter { $0.2.start < end && $0.2.end > start }
                    var baseline: [String:Double] = [:]
                    for hour in hourRecords {
                        let offset = (hour.2.start-start)/3600
                        try requireStorage(hour.2.start >= start && hour.2.end <= end &&
                            abs(hour.2.end-hour.2.start-3600) < 0.001 && abs(offset.rounded()-offset) < 0.000001,
                            "Unsafe outside-day hourly baseline.", "unsupported_schema")
                        for (bundle,app) in try NativeAppTotals.apps(hour.2.value) { baseline[bundle,default:0] += app.duration }
                    }
                    if let day = dayRecords.first {
                        try requireStorage(dayRecords.count == 1 && abs(day.2.start-start) < 0.01 && abs(day.2.end-end) < 0.01,
                            "Conflicting outside-day Daily interval.", "unsupported_schema")
                        let dailyTotals = try NativeAppTotals.apps(day.2.value).mapValues { $0.duration }
                        // Daily may include more hours, but cannot erase any
                        // already observed per-app hourly contribution.
                        try requireStorage(baseline.allSatisfy { (dailyTotals[$0.key] ?? 0) + 0.01 >= $0.value },
                            "Outside-day Daily/Hourly totals disagree.", "unsupported_schema")
                        baseline = dailyTotals
                    }
                    for (bundle,amount) in baseline { weekTotals[bundle,default:0] += amount }
                }
                cursor = next
            }
        }
        try requireStorage(weekTotals.values.allSatisfy { $0.isFinite && $0 >= 0 },
                           "Weekly app total overflow.", "unsupported_schema")
        plans.append(NativeCacheWrite(path: weeklyPath, original: weekly?.1,
            replacement: try weekly == nil
                ? NativeAppTotals.synthesized(weeklySegment, totals: weekTotals, catalog:catalog)
                : NativeAppTotals.replacing(weeklySegment, totals: weekTotals, catalog:catalog),
            template:weekly?.0 ?? template.0))
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
            let path = found?.0 ?? template.0.deletingLastPathComponent().appendingPathComponent(String(format: "%.1f.plist", start))
            plans.append(NativeCacheWrite(path: path, original: found?.1,
                replacement: try found == nil
                    ? NativeAppTotals.synthesized(segment, totals: NativeAppTotals.durations(request, start: start, end: end), catalog: catalog)
                    : NativeAppTotals.replacing(segment, totals: NativeAppTotals.durations(request, start: start, end: end), catalog: catalog),
                template: found?.0 ?? template.0))
        }
        // Future lastUpdatedDate is the Gemini bypass. Preserve any longer
        // existing freeze, and also cover edits whose end is later than now.
        let until = Date(timeIntervalSinceReferenceDate: max(now.timeIntervalSinceReferenceDate, request.end) + 30 * 86400)
        let hourlyMetadataPath = root.appendingPathComponent("Hourly/Metadata.plist")
        let hourlyMetadata = try boundedBytes(hourlyMetadataPath)
        for granularity in ["Hourly", "Daily", "Weekly"] {
            let path = root.appendingPathComponent(granularity + "/Metadata.plist")
            try rejectLinks(path)
            var info = stat()
            if lstat(path.path,&info) == 0 {
                let old = try boundedBytes(path)
                plans.append(NativeCacheWrite(path:path,original:old,
                    replacement:try NativeAppTotals.metadata(old,until:until),template:path))
            } else {
                try requireStorage(errno == ENOENT && granularity != "Hourly","Cannot inspect native metadata.","read_failed")
                plans.append(NativeCacheWrite(path:path,original:nil,
                    replacement:try NativeAppTotals.synthesizedMetadata(hourlyMetadata,granularity:granularity,until:until),
                    template:hourlyMetadataPath))
            }
        }
        try requireStorage(Set(plans.map { $0.path.path }).count == plans.count, "Duplicate cache write plan.", "unsupported_schema")
        return plans  // metadata is last, only after every segment is written
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
