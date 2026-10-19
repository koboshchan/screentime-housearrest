import Foundation
import Darwin

@main struct NativeAggregateChecks {
    static var count = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        count += 1
        if try !value() { throw StorageFailure("test_failed",label) }
    }
    static func rejects(_ label: String, _ work: () throws -> Void) throws {
        var failed = false
        do { try work() } catch { failed = true }
        try check(failed,label)
    }
    static func main() throws {
        let revision = String(repeating:"0",count:64)
        let request = ApplyRequest(start:100,end:400,sessions:[
            StoredSession(bundle:"com.example.a",start:120,end:200),
            StoredSession(bundle:"com.example.b",start:150,end:250),
            StoredSession(bundle:"com.example.c",start:300,end:360)],revision:revision)
        let records = try [(50.0,true),(180.0,false),(420.0,true)].map {
            SegmentRecord(timestamp:$0.0,flag:77,payload:try NativeAggregates.backlightPayload($0.0,$0.1))
        }
        let original = try Segment(created:1,flags:23,reserved:456,size:8192,records:records).encoded()
        let result = try Segment.parse(NativeAggregates.backlight(original,history:records,request:request,now:500))
        try check(result.records.map(\.timestamp) == [50,100,120,250,300,360,400,420],"union and gap boundaries")
        try check(try result.records.map { try NativeAggregates.backlightState($0) } == [true,false,true,false,true,false,false,true],"union states and original boundary")
        try check(result.created == 1 && result.flags == 23 && result.reserved == 456 && result.size == 8192,"SEGB metadata retained")
        try check(result.records.first?.flag == 77 && result.records.last?.payload == records.last?.payload,"outside payload and flags preserved")
        let future = try Segment.parse(NativeAggregates.backlight(original,history:records,request:request,now:380))
        try check(!future.records.contains { $0.timestamp == 400 },"no fake future restore")
        let empty = ApplyRequest(start:100,end:400,sessions:[],revision:revision)
        let cleared = try Segment.parse(NativeAggregates.backlight(original,history:records,request:empty,now:500))
        try check(cleared.records.map(\.timestamp) == [50,100,400,420],"empty day baseline and preserved boundary")
        let onHistory = [records[0]]
        let onOriginal = try Segment(created:0,size:4096,records:onHistory).encoded()
        let restored = try Segment.parse(NativeAggregates.backlight(onOriginal,history:onHistory,request:empty,now:500))
        try check(try NativeAggregates.backlightState(restored.records.last!),"past boundary restores prior on")
        let exact = records + [SegmentRecord(timestamp:400,payload:try NativeAggregates.backlightPayload(400,true))]
        let exactData = try Segment(created:0,size:4096,records:exact).encoded()
        let exactResult = try Segment.parse(NativeAggregates.backlight(exactData,history:exact,request:empty,now:500))
        try check(try NativeAggregates.backlightState(exactResult.records.last(where:{$0.timestamp == 400})!),"exact boundary wins")
        let blank = try Segment(created:0,size:4096,records:[]).encoded()
        for clock in [90.0,380.0,500.0] {
            let synthesized = try Segment.parse(NativeAggregates.backlight(blank,history:[],request:request,now:clock))
            try check(synthesized.records.map(\.timestamp) == [100,120,250,300,360,400],
                      "missing boundary synthesizes closed interval independent of now")
            try check(try synthesized.records.map { try NativeAggregates.backlightState($0) } == [false,true,false,true,false,false],
                      "missing boundary keeps overlapping sessions and gaps, never ongoing on")
        }
        let firstLater = [SegmentRecord(timestamp:450,flag:77,payload:try NativeAggregates.backlightPayload(450,true)),
                          SegmentRecord(timestamp:470,flag:91,payload:try NativeAggregates.backlightPayload(470,false)),
                          SegmentRecord(state:2,timestamp:480,payload:Data([123]))]
        let laterData = try Segment(created:1,flags:23,reserved:456,size:8192,records:firstLater).encoded()
        let beforeFirst = try Segment.parse(NativeAggregates.backlight(laterData,history:firstLater,request:request,now:500))
        try check(beforeFirst.records.suffix(3).map(\.payload) == firstLater.map(\.payload) &&
                  beforeFirst.records.suffix(3).map(\.flag) == firstLater.map(\.flag),
                  "actual missing-boundary shape preserves all later native and opaque records")
        try check(beforeFirst.created == 1 && beforeFirst.flags == 23 && beforeFirst.reserved == 456 &&
                  beforeFirst.size == 8192,"missing-boundary synthesis preserves segment envelope")
        let clearBlank = try Segment.parse(NativeAggregates.backlight(blank,history:[],request:empty,now:500))
        try check(clearBlank.records.map(\.timestamp) == [100,400] &&
                  clearBlank.records.allSatisfy { (try? NativeAggregates.backlightState($0)) == false },
                  "empty edit without original history remains closed off")
        let opaqueEnd = SegmentRecord(state:2,timestamp:400,payload:Data([123]))
        try rejects("unknown exact closing boundary conflicts with synthesis") {
            _ = try NativeAggregates.backlight(laterData,history:firstLater+[opaqueEnd],request:request,now:500)
        }
        let opaqueInside = SegmentRecord(state:2,timestamp:200,payload:Data([123]))
        try rejects("missing boundary never bypasses unknown interval schema") {
            _ = try NativeAggregates.backlight(laterData,history:firstLater+[opaqueInside],request:request,now:500)
        }
        let overlapDay = ApplyRequest(start:1000,end:87400,sessions:[
            StoredSession(bundle:"com.example.a",start:4600,end:46000),
            StoredSession(bundle:"com.example.b",start:4600,end:85540),
            StoredSession(bundle:"com.example.c",start:4600,end:85360)],revision:revision)
        let futureOverlap = try Segment.parse(NativeAggregates.backlight(blank,history:[],request:overlapDay,now:5000))
        try check(overlapDay.sessions.reduce(0.0) { $0+$1.end-$1.start } > 86400,
                  "overlapping app total exceeds 24 hours intentionally")
        try check(futureOverlap.records.map(\.timestamp) == [1000,4600,85540,87400],
                  "future long union is not clamped to now or app sum")
        try check(try futureOverlap.records.map { try NativeAggregates.backlightState($0) } == [false,true,false,false],
                  "future missing-boundary union is explicitly closed")
        try rejects("unknown protobuf schema") {
            _ = try NativeAggregates.backlight(original,history:[SegmentRecord(timestamp:1,payload:Data([8,1]))],request:empty,now:500)
        }
        try rejects("mismatched backlight clocks") {
            _ = try NativeAggregates.backlight(original,history:[SegmentRecord(timestamp:1,payload:NativeAggregates.backlightPayload(2,true))],request:empty,now:500)
        }
        let skewed = [
            SegmentRecord(timestamp:50,flag:77,payload:try NativeAggregates.backlightPayload(49.9982,true)),
            SegmentRecord(timestamp:180,payload:try NativeAggregates.backlightPayload(179.9977,false)),
            SegmentRecord(timestamp:420,flag:91,payload:try NativeAggregates.backlightPayload(419.9989,true))]
        let skewedData = try Segment(created:0,size:4096,records:skewed).encoded()
        let skewedResult = try Segment.parse(NativeAggregates.backlight(skewedData,history:skewed,request:empty,now:500))
        try check(skewedResult.records.first?.payload == skewed[0].payload && skewedResult.records.first?.flag == 77 &&
                  skewedResult.records.last?.payload == skewed[2].payload && skewedResult.records.last?.flag == 91,
                  "bounded native capture skew retains outside bytes and flags")
        try check(try !NativeAggregates.backlightState(skewedResult.records.first { $0.timestamp == 400 }!),
                  "bounded skew retains elapsed restore state")
        for edge in [100.0,400.0] {
            let row = SegmentRecord(timestamp:edge+0.001,payload:try NativeAggregates.backlightPayload(edge-0.001,true))
            try rejects("small skew crossing edit boundary fails closed") {
                _ = try NativeAggregates.backlight(skewedData,history:skewed+[row],request:empty,now:500)
            }
        }
        let exactSkew = SegmentRecord(timestamp:100,payload:try NativeAggregates.backlightPayload(99.999,true))
        try rejects("exact boundary skew fails closed") {
            _ = try NativeAggregates.backlight(skewedData,history:skewed+[exactSkew],request:empty,now:500)
        }
        let reorder = [
            SegmentRecord(timestamp:50,payload:try NativeAggregates.backlightPayload(50.002,true)),
            SegmentRecord(timestamp:50.001,payload:try NativeAggregates.backlightPayload(49.999,false))]
        try rejects("small skew reversing native event order fails closed") {
            _ = try NativeAggregates.backlight(skewedData,history:reorder,request:empty,now:500)
        }
        let coverageBoundary = SegmentRecord(timestamp:80.001,payload:try NativeAggregates.backlightPayload(79.999,true))
        try rejects("small skew crossing preserved coverage boundary fails closed") {
            _ = try NativeAggregates.backlight(skewedData,history:skewed+[coverageBoundary],request:empty,now:500,
                                              preserved:[StoredSession(bundle:"com.example.before",start:80,end:90)])
        }
        try rejects("capture skew at cap fails closed") {
            _ = try NativeAggregates.backlightState(SegmentRecord(timestamp:1,payload:NativeAggregates.backlightPayload(1.006,true)))
        }
        var corrupt = original; corrupt[40] ^= 1
        try rejects("CRC rejected") { _ = try Segment.parse(corrupt) }
        func usage(_ events: [UsageEvent]) throws -> Data {
            try Segment(created:0,size:8192,records:events.map { SegmentRecord(timestamp:$0.time,payload:try AppUsageProto.encode($0)) }).encoded()
        }
        let dangling = try usage([
            UsageEvent(opening:true,time:10,bundle:"com.example.open"),
            UsageEvent(opening:true,time:20,bundle:"com.example.open"),
            UsageEvent(opening:true,time:30,bundle:"com.example.closed"),
            UsageEvent(opening:false,time:40,bundle:"com.example.closed")])
        let normalized = try Segment.parse(NativeAggregates.usage(dangling,request:empty))
        let closes = normalized.records.filter { $0.timestamp == 99.999 }
        try check(closes.count == 1,"only latest dangling start closed")
        try check(try AppUsageProto.decode(closes[0].payload).bundle == "com.example.open","closed history not rewritten")
        try check(try pairUsage(normalized.records.map { var e = try AppUsageProto.decode($0.payload); e.time = $0.timestamp; return e }).contains(StoredSession(bundle:"com.example.closed",start:30,end:40)),"closed past session unchanged")
        let crossing = try usage([UsageEvent(opening:true,time:50,bundle:"com.example.cross"),
                                  UsageEvent(opening:false,time:450,bundle:"com.example.cross")])
        let fixedCrossing = try Segment.parse(NativeAggregates.usage(crossing,request:empty))
        try check(fixedCrossing.records.map(\.timestamp) == [50,99.999,400,450],"both crossing outside portions preserved")
        let base = URL(fileURLWithPath:"/private/tmp/ste-aggregate-"+UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:base) }
        let stream = base.appendingPathComponent("usage"), backlight = base.appendingPathComponent("backlight")
        for path in [stream,backlight] { try FileManager.default.createDirectory(at:path,withIntermediateDirectories:true) }
        let a = stream.appendingPathComponent("1"), b = stream.appendingPathComponent("2")
        try privateWrite(dangling,a); try privateWrite(usage([]),b)
        let store = NativeStorage(database:base.appendingPathComponent("unused.db"),stream:stream,backups:base.appendingPathComponent("backup"),backlightStream:backlight)
        try rejects("cross segment dangling starts fail before backup") { _ = try store.prepareNativeUsage(empty) }
        try FileManager.default.removeItem(at:a)
        try privateWrite(usage([UsageEvent(opening:true,time:1,bundle:"com.example.closed"),UsageEvent(opening:false,time:2,bundle:"com.example.closed")]),a)
        try check(try store.prepareNativeUsage(empty).count == 1,"old closed segment accepted")
        let backA = backlight.appendingPathComponent("1"), backB = backlight.appendingPathComponent("2")
        try privateWrite(original,backA); try privateWrite(original,backB)
        try rejects("overlapping backlight segments fail before backup") { _ = try store.prepareBacklight(empty) }
        try FileManager.default.removeItem(at:backA)
        try rejects("unknown preserved history boundary fails closed") { _ = try store.prepareBacklight(empty) }
        try FileManager.default.removeItem(at:a)
        try privateWrite(usage([]),a)
        try check(try store.prepareBacklight(empty).count == 1,"single backlight plan")

        var cal = Calendar(identifier:.gregorian)
        cal.timeZone = TimeZone(identifier:"America/Vancouver")!
        let day = 813913200.0, dayEnd = 813999600.0, hour = 813924000.0
        let partial = ApplyRequest(start:day,end:813922166,sessions:[
            StoredSession(bundle:"com.apple.mobilesafari",start:day+1800,end:day+3600),
            StoredSession(bundle:"com.apple.Preferences",start:day+4320,end:day+7920),
            StoredSession(bundle:"com.kobosh.screentimeeditor",start:813921179.610130,end:813922165.994653)],revision:revision)
        let naturals = [
            UsageEvent(opening:false,time:813923384.336326,bundle:"com.apple.Preferences"),
            UsageEvent(opening:true,time:813923384.491764,bundle:"com.apple.Preferences"),
            UsageEvent(opening:false,time:813923406.971060,bundle:"com.apple.Preferences"),
            UsageEvent(opening:true,time:813923407.112081,bundle:"com.apple.Preferences"),
            UsageEvent(opening:false,time:813924247.819759,bundle:"com.apple.Preferences")]
        let naturalData = try usage(naturals)
        let naturalRows = try Segment.parse(naturalData).records
        let preserved = try NativeAggregates.preservedUsage(naturalRows,request:partial,calendar:cal)
        try check(preserved.count == 2,"orphan stop never invented")
        let fragment = preserved.reduce(0.0) { $0 + max(0,min($1.end,hour)-$1.start) }
        try check(abs(fragment-615.3672150373459) < 0.000001,"actual 22.479296 plus 592.887919 closed-hour discrepancy")
        let off = SegmentRecord(timestamp:day-10,payload:try NativeAggregates.backlightPayload(day-10,false))
        let oldOn = SegmentRecord(timestamp:day+13000,flag:77,payload:try NativeAggregates.backlightPayload(day+13000,true))
        let oldOff = SegmentRecord(timestamp:day+14000,payload:try NativeAggregates.backlightPayload(day+14000,false))
        let nextDay = SegmentRecord(timestamp:dayEnd+1,payload:try NativeAggregates.backlightPayload(dayEnd+1,true))
        let opaque = SegmentRecord(state:2,timestamp:dayEnd+2,flag:91,payload:Data([123]))
        let display = [off,oldOn,oldOff,nextDay,opaque]
        let displayData = try Segment(created:1,flags:23,reserved:456,size:8192,records:display).encoded()
        let corrected = try Segment.parse(NativeAggregates.backlight(displayData,history:display,request:partial,now:hour+1000,preserved:preserved))
        func state(_ time: Double) throws -> Bool {
            try NativeAggregates.backlightState(corrected.records.last { $0.state == 1 && $0.timestamp <= time }!)
        }
        try check(try state(813923390),"first natural gains coverage")
        try check(try !state(813923407),"real 141ms gap retained")
        try check(try state(hour-1),"second natural gains closed-hour coverage")
        try check(try !state(813924248),"original off state restored")
        try check(try state(day+13500),"existing unrelated on coverage preserved")
        try check(corrected.records.contains { $0.timestamp == nextDay.timestamp && $0.payload == nextDay.payload },"outside-day state bytes retained")
        try check(corrected.records.contains { $0.state == 2 && $0.payload == opaque.payload },"outside opaque event retained")
        try check(try Segment.parse(naturalData).records.map(\.payload) == naturalRows.map(\.payload),"natural AppUsage bytes unchanged")
        let crossingDay = try usage([UsageEvent(opening:true,time:dayEnd-10,bundle:"com.example.end"),UsageEvent(opening:false,time:dayEnd+10,bundle:"com.example.end")])
        let clipped = try NativeAggregates.preservedUsage(Segment.parse(crossingDay).records,request:partial,calendar:cal)
        try check(clipped == [StoredSession(bundle:"com.example.end",start:dayEnd-10,end:dayEnd)],"selected day clips exactly at 813999600")
        let ambiguous = try usage([UsageEvent(opening:true,time:day+10,bundle:"com.example.a"),UsageEvent(opening:true,time:day+20,bundle:"com.example.a"),UsageEvent(opening:false,time:day+30,bundle:"com.example.a")])
        try rejects("duplicate natural starts fail closed") { _ = try NativeAggregates.preservedUsage(Segment.parse(ambiguous).records,request:partial,calendar:cal) }
        let wholeDay = ApplyRequest(start:day,end:dayEnd,sessions:[],revision:revision)
        try check(try NativeAggregates.preservedUsage(Segment.parse(ambiguous).records,request:wholeDay,calendar:cal).isEmpty,
                  "duplicate starts entirely replaced by full-day edit need no preserved coverage")
        let fromYesterday = try usage([
            UsageEvent(opening:true,time:day-10,bundle:"com.example.a"),
            UsageEvent(opening:true,time:day+20,bundle:"com.example.a"),
            UsageEvent(opening:false,time:day+30,bundle:"com.example.a")])
        try check(try NativeAggregates.preservedUsage(Segment.parse(fromYesterday).records,request:wholeDay,calendar:cal).isEmpty,
                  "full-day replacement never reconstructs uncertain pre-day usage")
        try rejects("partial day still rejects ambiguous crossing history") {
            _ = try NativeAggregates.preservedUsage(Segment.parse(fromYesterday).records,request:partial,calendar:cal)
        }
        let unknownDay = SegmentRecord(state:2,timestamp:day+10,payload:Data([1]))
        try rejects("full-day ambiguity allowance does not bypass unknown schema") {
            _ = try NativeAggregates.preservedUsage([unknownDay],request:wholeDay,calendar:cal)
        }
        let beforeSource = try usage([UsageEvent(opening:true,time:day-50,bundle:"com.example.before"),
                                     UsageEvent(opening:false,time:day-10,bundle:"com.example.before")])
        let earlierRows = try Segment.parse(beforeSource).records
        let fullRewrite = try Segment.parse(NativeAggregates.usage(beforeSource,request:wholeDay))
        try check(fullRewrite.records.map(\.payload) == earlierRows.map(\.payload),
                  "full-day change preserves closed earlier history byte for byte")
        let openOnly = try usage([UsageEvent(opening:true,time:hour,bundle:"com.example.open")])
        try check(try NativeAggregates.preservedUsage(Segment.parse(openOnly).records,request:partial,calendar:cal).isEmpty,"ongoing usage never assigned invented end")
        let unknown = SegmentRecord(state:2,timestamp:813923390,payload:Data([1]))
        try rejects("opaque inside added coverage fails closed") { _ = try NativeAggregates.backlight(displayData,history:display+[unknown],request:partial,now:hour+1000,preserved:preserved) }

        let before = [StoredSession(bundle:"com.example.before",start:80,end:100)]
        let beforeData = try NativeAggregates.backlight(onOriginal,history:onHistory,request:empty,now:500,preserved:before)
        let beforeRows = try Segment.parse(beforeData).records
        try check(try !NativeAggregates.backlightState(beforeRows.last { $0.timestamp <= 110 }!),"preserved pre-edit natural does not override edit baseline")
        print("PASS native aggregate \(count) checks; synthetic streams only")
    }
}
