import Foundation

enum AppTotalFixtures {
    static let a = "com.apple.mobilesafari"
    static let b = "com.apple.Preferences"
    static func document(start: Double, duration: Double, a: Double = 100, b: Double = 100) -> [String: Any] {
        ["value": [
            "recordZoneName": "fixture",
            "dateInterval": ["start": Date(timeIntervalSinceReferenceDate: start), "duration": duration],
            "firstPickup": Date(timeIntervalSinceReferenceDate: start),
            "longestActivity": ["start": Date(timeIntervalSinceReferenceDate: start), "duration": min(60, duration)],
            "totalActivityDuration": 999999.0,
            "totalPickupsWithoutApplicationActivity": 0,
            "categoryActivities": [
                ["identifier": "DH0012", "totalActivityDuration": 999999.0,
                 "applicationActivities": [
                    ["bundleIdentifier": self.a, "totalActivityDuration": a,
                     "numberOfPickups": 1, "numberOfNotifications": 0, "isTrusted": true]],
                 "webDomainActivities": [["domain": "example.invalid", "totalActivityDuration": 999999.0]]],
                ["identifier": "DH0013", "totalActivityDuration": 999999.0,
                 "applicationActivities": [
                    ["bundleIdentifier": self.b, "totalActivityDuration": b,
                     "numberOfPickups": 0, "numberOfNotifications": 1, "isTrusted": true]],
                 "webDomainActivities": [[String: Any]]()]
            ]
        ]]
    }
    static func bytes(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    static func create(_ root: URL, start: Double = 0, duration: Double = 86400) throws {
        for (gran, interval, a, b) in [("Hourly",3600.0,100.0,100.0),("Daily",duration,100.0,100.0),("Weekly",604800.0,300.0,300.0)] {
            let dir = root.appendingPathComponent(gran + "/ActivitySegments")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent(String(format: "%.1f.plist", start))
            try privateWrite(bytes(document(start: start, duration: interval, a: a, b: b)), path)
            try privateWrite(bytes(["value": ["lastUpdatedDate": Date(timeIntervalSinceReferenceDate: start),
                                             "untouched": "sentinel"]]), root.appendingPathComponent(gran + "/Metadata.plist"))
        }
    }
}
