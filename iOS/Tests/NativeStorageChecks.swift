import Foundation
import SQLite3
import Darwin
@main struct NativeStorageChecks {
    static var count = 0
    static func check(_ ok: @autoclosure () throws -> Bool, _ label: String) throws {
        count += 1
        if try !ok() { throw StorageFailure("test_failed",label) }
    }
    static func rejects(_ label: String, _ work: () throws -> Void) throws {
        var rejected = false
        do { try work() } catch { rejected = true }
        try check(rejected,label)
    }
    static func main() throws {
        // All sources are newly created fixtures. Never instantiate device layout.
        let base = URL(fileURLWithPath:"/private/tmp").appendingPathComponent("ste-native-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let stream = base.appendingPathComponent("local"), dbURL = base.appendingPathComponent("knowledgeC.db"), backup = base.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at:stream,withIntermediateDirectories:false)
        var db: OpaquePointer?
        try check(sqlite3_open(dbURL.path,&db) == SQLITE_OK,"fixture db")
        try check(sqlite3_exec(db,"CREATE TABLE ZOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZSTREAMNAME TEXT, ZSTARTDATE REAL, ZENDDATE REAL, ZVALUESTRING TEXT, ZCREATIONDATE REAL); INSERT INTO ZOBJECT VALUES(1,1,1,'/app/usage',900,2500,'com.example.old',900);",nil,nil,nil) == SQLITE_OK,"schema")
        sqlite3_close(db)
        let a = UsageEvent(opening:true,time:900,bundle:"com.example.old"), b = UsageEvent(opening:false,time:2500,bundle:"com.example.old")
        let records = try [a,b].map { SegmentRecord(timestamp:$0.time,payload:try AppUsageProto.encode($0)) }
        let segment = Segment(created:500,size:4096,records:records)
        let path = stream.appendingPathComponent("0000000002")
        try privateWrite(segment.encoded(),path)
        let store = NativeStorage(database:dbURL,stream:stream,backups:backup)
        let snapshot = try store.readSnapshot()
        try check(snapshot.sessions == [StoredSession(bundle:"com.example.old",start:900,end:2500)],"footer read")
        try check(snapshot.revision.count == 64,"fingerprint")
        let backupID = try store.backup()
        try check(try store.verifyBackup(backupID) == snapshot.revision,"verified backup")
        let request = ApplyRequest(start:1000,end:2000,sessions:[StoredSession(bundle:"com.example.new",start:1100,end:1800)],revision:snapshot.revision)
        let result = try store.apply(request)
        try check(result.ok,"apply")
        try check(result.details["backupID"] != backupID,"fresh backup each apply")
        let after = try store.readSnapshot()
        try check(after.sessions.contains(StoredSession(bundle:"com.example.old",start:900,end:1000)),"left crossing")
        try check(after.sessions.contains(StoredSession(bundle:"com.example.old",start:2000,end:2500)),"right crossing")
        try check(after.sessions.contains(StoredSession(bundle:"com.example.new",start:1100,end:1800)),"edited session")
        try rejects("stale rejected") { _ = try store.apply(request) }
        var override = request; override.overrideSourceChanges = true
        let over = try store.apply(override)
        try check(over.ok && over.details["backupID"] != result.details["backupID"],"override fresh CURRENT backup")
        try check(try store.verifyBackup(over.details["backupID"]!) == after.revision,"override backed current not stale")
        let copied = backup.appendingPathComponent(backupID).appendingPathComponent("segment-0000000002")
        let fd = open(copied.path,O_WRONLY); var byte: UInt8 = 0; _ = pwrite(fd,&byte,1,0); close(fd)
        try rejects("corruption rejected") { _ = try store.verifyBackup(backupID) }
        try rejects("traversal rejected") { _ = try store.verifyBackup("../x") }
        var corrupt = try segment.encoded(); corrupt[40] ^= 1
        try rejects("CRC rejects") { _ = try Segment.parse(corrupt) }
        var footer = try segment.encoded(); footer.put32(4096,footer.count-16)
        try rejects("footer overlap rejects") { _ = try Segment.parse(footer) }
        try rejects("truncated rejects") { _ = try Segment.parse(Data([1,2])) }
        let longBundle = "com."+String(repeating:"a",count:140)
        try check(try AppUsageProto.decode(AppUsageProto.encode(UsageEvent(opening:true,time:123,bundle:longBundle))).bundle == longBundle,"multibyte varint")
        try rejects("overflow protobuf rejects") { _ = try AppUsageProto.decode(Data(repeating:255,count:11)) }
        var opaque = segment
        opaque.records.insert(SegmentRecord(state:3,timestamp:500,payload:Data()),at:0)
        try check(try Segment.parse(opaque.encoded()).records[0].state == 3,"opaque state preserved")
        var huge = segment; huge.size = 80
        try rejects("capacity fails before writing") { _ = try huge.encoded() }
        let link = stream.appendingPathComponent("symlink")
        try FileManager.default.createSymbolicLink(at:link,withDestinationURL:path)
        try rejects("symlink rejected") { _ = try store.readSnapshot() }
        try FileManager.default.removeItem(at:link)
        let invalid = ApplyRequest(start:1000,end:2000,sessions:[StoredSession(bundle:"bad/../../id",start:1100,end:1800)],revision:after.revision,overrideSourceChanges:true)
        try rejects("invalid id rejected") { _ = try store.apply(invalid) }
        let response = try StorageProtocol.handle(HelperRequest(op:.read),storage:store)
        try check(response.ok && response.details["snapshot"] != nil,"read protocol")
        print("PASS native storage \(count) checks, temporary synthetic stores only")
    }
}
