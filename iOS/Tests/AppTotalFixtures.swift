import Foundation
import CloudKit

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
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        for (name,value) in [("LocalFirstWeekday.plist",["value":2] as [String:Any]),
                              ("LocalTimeZone.plist",["value":["identifier":"GMT"]] as [String:Any])] {
            let path = root.deletingLastPathComponent().appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath:path.path) { try privateWrite(bytes(value),path) }
        }
        for (gran, interval, a, b) in [("Hourly",3600.0,100.0,100.0),("Daily",duration,100.0,100.0),("Weekly",604800.0,300.0,300.0)] {
            let dir = root.appendingPathComponent(gran + "/ActivitySegments")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent(String(format: "%.1f.plist", start))
            try privateWrite(bytes(document(start: start, duration: interval, a: a, b: b)), path)
            try privateWrite(bytes(["value": ["lastUpdatedDate": Date(timeIntervalSinceReferenceDate: start),
                                             "untouched": "sentinel",
                                             "device":["identifier":"fixture-device"],"user":["role":0],
                                             "recordName":"00000000-0000-4000-8000-000000000000_" + gran,
                                             "segmentInterval":gran == "Hourly" ? 0 : (gran == "Daily" ? 1 : 2)]]), root.appendingPathComponent(gran + "/Metadata.plist"))
        }
    }
    /// Synthetic secure CKRecord fields, never real account or device data.
    static func cloud(_ root: URL, today: Double = 0) throws -> URL {
        let identifier = "00000000-0000-4000-8000-000000000000"
        let parent = root.deletingLastPathComponent()
        try privateWrite(bytes(["value":identifier]),parent.appendingPathComponent("LocalDeviceIdentifier.plist"))
        let cloud = parent.appendingPathComponent("Cloud/fixture-account/"+identifier)
        let hourlyPath = root.appendingPathComponent("Hourly/Metadata.plist")
        var hourlyDoc = try PropertyListSerialization.propertyList(from:boundedBytes(hourlyPath),format:nil) as! [String:Any]
        var hourlyValue = hourlyDoc["value"] as! [String:Any]
        hourlyValue.removeValue(forKey:"untouched")
        hourlyValue["device"] = ["identifier":identifier,"coreDuetIdentifier":identifier,"name":"Fixture","model":1]
        hourlyValue["user"] = ["role":0,"appleID":"fixture@example.invalid","altDSID":"fixture","nameComponents":[:]]
        hourlyValue["lastUpdatedDate"] = Date(timeIntervalSinceReferenceDate:today)
        hourlyDoc["value"] = hourlyValue
        try FileManager.default.removeItem(at:hourlyPath)
        try privateWrite(bytes(hourlyDoc),hourlyPath)
        for gran in ["Hourly","Daily","Weekly"] {
            let target = cloud.appendingPathComponent(gran+"/ActivitySegments")
            try FileManager.default.createDirectory(at:target,withIntermediateDirectories:true)
            let zone = identifier+"_"+gran
            func identity(_ name: String,_ type: String) -> Data {
                let record = CKRecord(recordType:type,recordID:CKRecord.ID(recordName:name,zoneID:CKRecordZone.ID(zoneName:zone,ownerName:CKCurrentUserDefaultName)))
                let coder = NSKeyedArchiver(requiringSecureCoding:true)
                record.encodeSystemFields(with:coder); coder.finishEncoding()
                return coder.encodedData
            }
            let source = root.appendingPathComponent(gran+"/ActivitySegments")
            for path in try FileManager.default.contentsOfDirectory(at:source,includingPropertiesForKeys:nil) where path.pathExtension == "plist" {
                var doc = try PropertyListSerialization.propertyList(from:boundedBytes(path),format:nil) as! [String:Any]
                var value = doc["value"] as! [String:Any]
                if gran == "Weekly" {
                    var categories = value["categoryActivities"] as! [[String:Any]]
                    for i in categories.indices {
                        var apps = categories[i]["applicationActivities"] as! [[String:Any]]
                        for j in apps.indices { apps[j]["totalActivityDuration"] = 100.0 * (today/86400+1) }
                        categories[i]["applicationActivities"] = apps
                    }
                    value["categoryActivities"] = categories
                }
                value["recordZoneName"] = zone
                value["recordSystemFields"] = identity(path.deletingPathExtension().lastPathComponent,"ActivitySegment")
                doc["value"] = value
                try privateWrite(bytes(doc),target.appendingPathComponent(path.lastPathComponent))
            }
            if gran == "Daily" && today > 0 {
                var doc = document(start:today,duration:86400)
                var value = doc["value"] as! [String:Any]
                value["recordZoneName"] = zone
                value["recordSystemFields"] = identity(String(format:"%.1f",today),"ActivitySegment")
                doc["value"] = value
                try privateWrite(bytes(doc),target.appendingPathComponent(String(format:"%.1f.plist",today)))
            }
            var doc = try PropertyListSerialization.propertyList(from:boundedBytes(root.appendingPathComponent(gran+"/Metadata.plist")),format:nil) as! [String:Any]
            var value = doc["value"] as! [String:Any]
            value.removeValue(forKey:"untouched")
            value["device"] = hourlyValue["device"]
            value["user"] = hourlyValue["user"]
            value["lastUpdatedDate"] = Date(timeIntervalSinceReferenceDate:today)
            value["recordSystemFields"] = identity(zone,"Metadata")
            doc["value"] = value
            try privateWrite(bytes(doc),cloud.appendingPathComponent(gran+"/Metadata.plist"))
        }
        return cloud
    }

}
