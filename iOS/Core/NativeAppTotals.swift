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
                throw StorageFailure("unsupported_schema", "No native cache app template for \(bundle). Open Screen Time after using this app, then reload.")
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
                // No native category aggregate exists in this segment. Do not
                // invent or copy a different interval's category total.
                category["totalActivityDuration"] = 0.0
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
        guard let daily, let weekly else {
            throw StorageFailure("incomplete_baseline", "Native Daily and Weekly baselines are required. Missing observations are not zero. Open Settings Screen Time Day and Week, then reload. Nothing applied.")
        }
        try rejectPreviouslySynthesized([daily, weekly], root: root)
        let dayTotals = NativeAppTotals.durations(request, start: request.start, end: request.end)
        let oldDay = try NativeAppTotals.apps(daily.2.value).mapValues { $0.duration }
        var plans = [NativeCacheWrite(path: daily.0, original: daily.1,
            replacement: try NativeAppTotals.replacing(daily.2, totals: dayTotals, catalog: catalog), template: daily.0)]
        var weekTotals = try NativeAppTotals.apps(weekly.2.value).mapValues { $0.duration }
        for bundle in Set(oldDay.keys).union(dayTotals.keys) {
            let outside = (weekTotals[bundle] ?? 0) - (oldDay[bundle] ?? 0)
            try requireStorage(outside >= -0.01 && outside.isFinite,
                "Weekly app cache is inconsistent with selected-day baseline; nothing applied.", "unsupported_schema")
            weekTotals[bundle] = max(0, outside) + (dayTotals[bundle] ?? 0)
        }
        try requireStorage(weekTotals.values.allSatisfy { $0.isFinite && $0 >= 0 },
                           "Weekly app total overflow.", "unsupported_schema")
        plans.append(NativeCacheWrite(path: weekly.0, original: weekly.1,
            replacement: try NativeAppTotals.replacing(weekly.2, totals: weekTotals, catalog: catalog), template: weekly.0))
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
        for granularity in ["Hourly", "Daily", "Weekly"] {
            let path = root.appendingPathComponent(granularity + "/Metadata.plist")
            try rejectLinks(path)
            var info = stat()
            if lstat(path.path,&info) == 0 {
                let old = try boundedBytes(path)
                plans.append(NativeCacheWrite(path:path,original:old,
                    replacement:try NativeAppTotals.metadata(old,until:until),template:path))
            } else {
                throw StorageFailure("incomplete_baseline", "Native refresh metadata is missing; nothing applied.")
            }
        }
        try requireStorage(Set(plans.map { $0.path.path }).count == plans.count, "Duplicate cache write plan.", "unsupported_schema")
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
