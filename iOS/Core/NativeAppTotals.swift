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
    let original: Data?  // nil only for a deterministic missing hourly bucket
    let replacement: Data
    let template: URL
}

extension NativeStorage {
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
            let paths = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "plist" }.sorted { $0.path < $1.path }
            try requireStorage(!paths.isEmpty && paths.count <= 10000, "Missing DeviceActivity \(granularity) templates.", "unsupported_schema")
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
        guard let daily = segments["Daily"]?.first(where: { abs($0.2.start-request.start) < 0.01 && abs($0.2.end-request.end) < 0.01 }),
              let weekly = segments["Weekly"]?.first(where: { $0.2.start <= request.start && $0.2.end >= request.end }),
              let hours = segments["Hourly"], let template = hours.first else {
            throw StorageFailure("unsupported_schema", "A full-day edit requires matching Daily and Weekly native cache templates.")
        }
        let dayTotals = NativeAppTotals.durations(request, start: request.start, end: request.end)
        var plans = [NativeCacheWrite(path: daily.0, original: daily.1,
            replacement: try NativeAppTotals.replacing(daily.2, totals: dayTotals, catalog: catalog), template: daily.0)]
        let oldDay = try NativeAppTotals.apps(daily.2.value), oldWeek = try NativeAppTotals.apps(weekly.2.value)
        var weekTotals = oldWeek.mapValues { $0.duration }
        for bundle in Set(oldDay.keys).union(dayTotals.keys) {
            let amount = (weekTotals[bundle] ?? 0) - (oldDay[bundle]?.duration ?? 0) + (dayTotals[bundle] ?? 0)
            try requireStorage(amount >= -0.01 && amount.isFinite, "Weekly app cache is inconsistent with Daily; nothing applied.", "unsupported_schema")
            weekTotals[bundle] = max(0, amount)
        }
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
                segment.value["dateInterval"] = ["start": Date(timeIntervalSinceReferenceDate: start), "duration": 3600.0]
                // Avoid copying another hour's pickup/longest-activity timestamps.
                segment.value.removeValue(forKey: "firstPickup")
                segment.value.removeValue(forKey: "longestActivity")
                segment.value["totalPickupsWithoutApplicationActivity"] = 0
                // Only requested apps belong in a newly created hour. Do not
                // clone historical website details, notifications or pickups.
                segment.value["categoryActivities"] = [[String: Any]]()
            }
            let path = found?.0 ?? template.0.deletingLastPathComponent().appendingPathComponent(String(format: "%.1f.plist", start))
            plans.append(NativeCacheWrite(path: path, original: found?.1,
                replacement: try NativeAppTotals.replacing(segment, totals: NativeAppTotals.durations(request, start: start, end: end), catalog: catalog),
                template: found?.0 ?? template.0))
        }
        // Future lastUpdatedDate is the Gemini bypass. Preserve any longer
        // existing freeze, and also cover edits whose end is later than now.
        let until = Date(timeIntervalSinceReferenceDate: max(now.timeIntervalSinceReferenceDate, request.end) + 30 * 86400)
        for granularity in ["Hourly", "Daily", "Weekly"] {
            let path = root.appendingPathComponent(granularity + "/Metadata.plist")
            let old = try boundedBytes(path)
            plans.append(NativeCacheWrite(path: path, original: old,
                replacement: try NativeAppTotals.metadata(old, until: until), template: path))
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
        try requireStorage(fd >= 0, "Hourly cache appeared or cannot be created.", "concurrent_change")
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
