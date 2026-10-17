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
        try rejects("unknown elapsed boundary") { _ = try NativeAggregates.backlight(Segment(created:0,size:4096,records:[]).encoded(),history:[],request:empty,now:500) }
        try rejects("unknown protobuf schema") {
            _ = try NativeAggregates.backlight(original,history:[SegmentRecord(timestamp:1,payload:Data([8,1]))],request:empty,now:500)
        }
        try rejects("mismatched backlight clocks") {
            _ = try NativeAggregates.backlight(original,history:[SegmentRecord(timestamp:1,payload:NativeAggregates.backlightPayload(2,true))],request:empty,now:500)
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
        try check(try store.prepareBacklight(empty).count == 1,"single backlight plan")

        print("PASS native aggregate \(count) checks; synthetic streams only")
    }
}
