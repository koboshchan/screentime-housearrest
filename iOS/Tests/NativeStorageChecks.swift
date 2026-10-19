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
        // Epoch-zero cache fixtures represent a complete UTC day.
        NSTimeZone.default = TimeZone(secondsFromGMT:0)!
        // All sources are newly created fixtures. Never instantiate device layout.
        let base = URL(fileURLWithPath:"/private/tmp").appendingPathComponent("ste-native-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:base,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:base) }
        let stream = base.appendingPathComponent("local"), dbURL = base.appendingPathComponent("knowledgeC.db"), backup = base.appendingPathComponent("Backups")
        try FileManager.default.createDirectory(at:stream,withIntermediateDirectories:false)
        var db: OpaquePointer?
        try check(sqlite3_open(dbURL.path,&db) == SQLITE_OK,"fixture db")
        try check(sqlite3_exec(db,"CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY,Z_NAME TEXT); INSERT INTO Z_PRIMARYKEY VALUES (11,'Event'); CREATE TABLE ZOBJECT (Z_PK INTEGER PRIMARY KEY, Z_ENT INTEGER, Z_OPT INTEGER, ZSTREAMNAME TEXT, ZSTARTDATE REAL, ZENDDATE REAL, ZVALUESTRING TEXT, ZCREATIONDATE REAL); INSERT INTO ZOBJECT VALUES(1,11,1,'/app/usage',900,2500,'com.example.old',900); INSERT INTO ZOBJECT VALUES(2,99,1,'/device/isLocked',1100,1800,'unrelated',1100);",nil,nil,nil) == SQLITE_OK,"schema")
        sqlite3_close(db)
        let a = UsageEvent(opening:true,time:900,bundle:"com.example.old"), b = UsageEvent(opening:false,time:2500,bundle:"com.example.old")
        let records = try [a,b].map { SegmentRecord(timestamp:$0.time,payload:try AppUsageProto.encode($0)) }
        let segment = Segment(created:500,size:4096,records:records)
        let path = stream.appendingPathComponent("0000000002")
        try privateWrite(segment.encoded(),path)
        let store = NativeStorage(database:dbURL,stream:stream,backups:backup)
        // Reader trusts state-1 footer clocks, not protobuf clocks. Invalid
        // historical payloads are skipped without inventing sessions.
        var timing = segment
        timing.records[0].payload = try AppUsageProto.encode(UsageEvent(opening:true,time:1,bundle:"com.example.old"))
        timing.records[1].payload = try AppUsageProto.encode(UsageEvent(opening:false,time:2,bundle:"com.example.old"))
        timing.records.append(SegmentRecord(timestamp:700,payload:Data([255])))
        let fdTiming = open(path.path,O_WRONLY)
        let timingBytes = try timing.encoded()
        _ = timingBytes.withUnsafeBytes { pwrite(fdTiming,$0.baseAddress,$0.count,0) }; close(fdTiming)
        let snapshot = try store.readSnapshot()
        try check(snapshot.sessions == [StoredSession(bundle:"com.example.old",start:900,end:2500)],"footer read")
        try check(snapshot.revision.count == 64,"fingerprint")
        try check(snapshot.sessions.first?.start == 900 && snapshot.sessions.first?.end == 2500,"footer clocks override payload clocks; malformed payload skipped")
        // Add an older segment whose unchanged session is included in the UI's
        // whole-day request. It must not be copied to the latest segment.
        let olderPath = stream.appendingPathComponent("0000000001")
        let olderRecords = try [UsageEvent(opening:true,time:1200,bundle:"com.example.older"),UsageEvent(opening:false,time:1500,bundle:"com.example.older")].map { SegmentRecord(timestamp:$0.time,payload:try AppUsageProto.encode($0)) }
        try privateWrite(Segment(created:400,size:4096,records:olderRecords).encoded(),olderPath)
        let olderOriginal = try boundedBytes(olderPath)
        let withOlder = try store.readSnapshot()
        let backupID = try store.backup()
        try check(try store.verifyBackup(backupID) == withOlder.revision,"verified backup")
        let request = ApplyRequest(start:1000,end:2000,sessions:[StoredSession(bundle:"com.example.new",start:1100,end:1800),StoredSession(bundle:"com.example.older",start:1200,end:1500)],revision:withOlder.revision)
        let result = try store.applyLegacyFixtures(request)
        try check(result.ok,"apply")
        try check(try boundedBytes(olderPath) == olderOriginal,"older segment unchanged")
        let latestAfter = try Segment.parse(boundedBytes(path))
        try check(!latestAfter.records.contains { (try? AppUsageProto.decode($0.payload).bundle) == "com.example.older" },"unchanged older session not duplicated into latest")

        do {
            let verify = try KnowledgeDatabase(dbURL)
            try check(verify.usageEntity == 11,"iOS entity 11 selected from metadata and usage")
            var entityOK = true, unrelated = 0
            try verify.query("SELECT Z_ENT FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage'") { row in entityOK = entityOK && sqlite3_column_int(row,0) == 11 }
            try verify.query("SELECT COUNT(*) FROM ZOBJECT WHERE ZSTREAMNAME='/device/isLocked' AND Z_ENT=99 AND ZVALUESTRING='unrelated'") { row in unrelated = Int(sqlite3_column_int(row,0)) }
            try check(entityOK,"all inserted iOS rows retain entity 11")
            try check(unrelated == 1,"unrelated overlapping lock row retained")
        }
        try check(result.details["backupID"] != backupID,"fresh backup each apply")
        let after = try store.readSnapshot()
        try check(after.sessions.contains(StoredSession(bundle:"com.example.old",start:900,end:1000)),"left crossing")
        try check(after.sessions.contains(StoredSession(bundle:"com.example.old",start:2000,end:2500)),"right crossing")
        try check(after.sessions.contains(StoredSession(bundle:"com.example.new",start:1100,end:1800)),"edited session")
        try rejects("stale rejected") { _ = try store.applyLegacyFixtures(request) }
        var override = request; override.overrideSourceChanges = true
        let over = try store.applyLegacyFixtures(override)
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
        try rejects("invalid id rejected") { _ = try store.applyLegacyFixtures(invalid) }
        do {
            let change = try KnowledgeDatabase(dbURL,writable:true)
            try change.execute("UPDATE Z_PRIMARYKEY SET Z_ENT=1 WHERE Z_ENT=11; UPDATE ZOBJECT SET Z_ENT=1 WHERE ZSTREAMNAME='/app/usage'")
        }
        do {
            let macSchema = try KnowledgeDatabase(dbURL)
            try check(macSchema.usageEntity == 1,"Mac fixture entity 1 resolved rather than hardcoded")
        }
        let macSnapshot = try store.readSnapshot()
        let macRequest = ApplyRequest(start:1000,end:2000,sessions:[StoredSession(bundle:"com.example.mac",start:1200,end:1900)],revision:macSnapshot.revision)
        _ = try store.applyLegacyFixtures(macRequest)
        do {
            let verify = try KnowledgeDatabase(dbURL)
            var entityOK = true
            try verify.query("SELECT Z_ENT FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage'") { row in entityOK = entityOK && sqlite3_column_int(row,0) == 1 }
            try check(entityOK,"Mac fixture inserted entity 1")
        }

        try check(SessionRules.isValidBundleID("com.example_with_under.app"),"underscore bundle parity")
        let parity = base.appendingPathComponent("parity")
        try FileManager.default.createDirectory(at:parity,withIntermediateDirectories:false)
        let usageDir = parity.appendingPathComponent("usage"), lockDir = parity.appendingPathComponent("locks")
        let groups = parity.appendingPathComponent("groups")
        let cache = groups.appendingPathComponent(UUID().uuidString+"/Library/com.apple.DeviceActivity/Local")
        for dir in [usageDir,lockDir,cache] { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }
        let cacheFile = cache.appendingPathComponent("day.plist")
        try privateWrite(Data("original cache".utf8),cacheFile)
        let parityDB = parity.appendingPathComponent("knowledgeC.db")
        var connection: OpaquePointer?
        try check(sqlite3_open(parityDB.path,&connection) == SQLITE_OK,"parity database")
        try check(sqlite3_exec(connection,"CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY,Z_NAME TEXT); INSERT INTO Z_PRIMARYKEY VALUES (43,'Usage'),(72,'Lock'); CREATE TABLE ZOBJECT (Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,Z_OPT INTEGER,ZSTREAMNAME TEXT,ZSTARTDATE REAL,ZENDDATE REAL,ZVALUESTRING TEXT,ZVALUEDOUBLE REAL,ZCREATIONDATE REAL); INSERT INTO ZOBJECT VALUES(1,43,1,'/app/usage',-100,0,'com.preceding.app',NULL,-100); INSERT INTO ZOBJECT VALUES(2,72,1,'/device/isLocked',-100,500,NULL,1,-100);",nil,nil,nil) == SQLITE_OK,"dynamic lock schema")
        sqlite3_close(connection)
        let usagePath = usageDir.appendingPathComponent("dynamic-name")
        let boundaryEvents = [UsageEvent(opening:true,time:-100,bundle:"com.preceding.app"),UsageEvent(opening:false,time:-0.0,bundle:"com.preceding.app")]
        let boundaryRecords = try boundaryEvents.map { SegmentRecord(timestamp:$0.time,payload:try AppUsageProto.encode($0)) }
        try privateWrite(Segment(created:-200,size:8192,records:boundaryRecords).encoded(),usagePath)
        let lockPath = lockDir.appendingPathComponent("not-a-hardcoded-segment")
        try privateWrite(Segment(created:-200,size:8192,records:[SegmentRecord(timestamp:-100,payload:Data([8,1])),SegmentRecord(timestamp:500,payload:Data([8,0]))]).encoded(),lockPath)
        var calls: [[String]] = []
        let parityStore = NativeStorage(database:parityDB,stream:usageDir,backups:parity.appendingPathComponent("Backups"),lockStream:lockDir,groupRoot:groups,runner:{ calls.append($0) })
        let initialParity = try parityStore.readSnapshot()
        let edit = ApplyRequest(start:0.0,end:300,sessions:[StoredSession(bundle:"com.example_with_under.app",start:60,end:180)],revision:initialParity.revision)
        let parityResult = try parityStore.applyLegacyFixtures(edit)
        try check(parityResult.ok && calls == [["Preferences","ScreenTimeSettingsAgent"]],"fixed refresh fake runner")
        try check(try FileManager.default.contentsOfDirectory(atPath:cache.path).isEmpty,"dynamic DeviceActivity cache cleared")
        let boundaryAfter = try parityStore.readSnapshot()
        try check(boundaryAfter.sessions.contains(StoredSession(bundle:"com.preceding.app",start:-100,end:0)),"end equal request start preserves closing event signed zero")
        let lockAfter = try Segment.parse(boundedBytes(lockPath))
        try check(lockAfter.records.contains { $0.timestamp == 60 && $0.payload == Data([8,0]) },"system lock unlock event")
        try check(lockAfter.records.contains { $0.timestamp == 180 && $0.payload == Data([8,1]) },"system lock closing event")
        let parityBackup = parity.appendingPathComponent("Backups").appendingPathComponent(parityResult.details["backupID"]!)
        let manifest = try JSONDecoder().decode(BackupManifest.self,from:boundedBytes(parityBackup.appendingPathComponent("manifest.json")))
        try check(manifest.files.contains { $0.name.hasPrefix("lock-") } && manifest.files.contains { $0.name.hasPrefix("cache-") },"all lock and cache stores backed up")
        try check(manifest.files.allSatisfy { $0.mode > 0 } && !manifest.directories.isEmpty,"ownership mode directory metadata backed up")
        try check(try parityStore.verifyBackup(parityResult.details["backupID"]!) == initialParity.revision,"full parity backup independently verified")
        do {
            let verify = try KnowledgeDatabase(parityDB)
            var unlocked = 0, outsideLocks = 0
            try verify.query("SELECT COUNT(*) FROM ZOBJECT WHERE ZSTREAMNAME='/device/isLocked' AND Z_ENT=72 AND ZVALUEDOUBLE=0 AND ZSTARTDATE=60 AND ZENDDATE=180") { row in unlocked = Int(sqlite3_column_int(row,0)) }
            try verify.query("SELECT COUNT(*) FROM ZOBJECT WHERE ZSTREAMNAME='/device/isLocked' AND (ZSTARTDATE=-100 OR ZENDDATE=500)") { row in outsideLocks = Int(sqlite3_column_int(row,0)) }
            try check(unlocked == 1 && outsideLocks == 2,"dynamic lock entity and boundary preservation")
        }
        let beforeMutation = try boundedBytes(usagePath)
        let fresh = try parityStore.readSnapshot()
        var mutationEdit = edit; mutationEdit.revision = fresh.revision
        parityStore.duringBackup = {
            let f = open(cache.appendingPathComponent("new.plist").path,O_WRONLY|O_CREAT,0o600); close(f)
        }
        var mutationCode = ""
        do { _ = try parityStore.applyLegacyFixtures(mutationEdit) } catch let e as StorageFailure { mutationCode = e.code }
        try check(mutationCode == "stale_revision","mutation during backup preserves stale_revision")
        try check(try boundedBytes(usagePath) == beforeMutation && calls.count == 1,"mutation backup fails before writes cache deletion or refresh")
        parityStore.duringBackup = nil
        try FileManager.default.removeItem(at:cache.appendingPathComponent("new.plist"))
        let transactionSnap = try parityStore.readSnapshot()
        mutationEdit.revision = transactionSnap.revision
        parityStore.beforeTransactionWrite = {
            let f = open(cache.appendingPathComponent("race.plist").path,O_WRONLY|O_CREAT,0o600); close(f)
        }
        mutationCode = ""
        do { _ = try parityStore.applyLegacyFixtures(mutationEdit) } catch let e as StorageFailure { mutationCode = e.code }
        try check(mutationCode == "stale_revision","transaction prewrite stale not catchwrapped")
        try check(try boundedBytes(usagePath) == beforeMutation && calls.count == 1,"prewrite stale has no usage mutation or refresh")
        parityStore.beforeTransactionWrite = nil

        try FileManager.default.removeItem(at:cache.appendingPathComponent("race.plist"))
        let zeroOlderPath = usageDir.appendingPathComponent("000-older")
        let zeroEvents = [UsageEvent(opening:true,time:-0.0,bundle:"com.zero.app"),UsageEvent(opening:false,time:100,bundle:"com.zero.app")]
        let zeroRecords = try zeroEvents.map { SegmentRecord(timestamp:$0.time,payload:try AppUsageProto.encode($0)) }
        try privateWrite(Segment(created:-200,size:8192,records:zeroRecords).encoded(),zeroOlderPath)
        let zeroSnapshot = try parityStore.readSnapshot()
        let zeroEdit = ApplyRequest(start:0,end:300,sessions:[StoredSession(bundle:"com.zero.app",start:0.0,end:100)],revision:zeroSnapshot.revision)
        _ = try parityStore.applyLegacyFixtures(zeroEdit)
        let latestZero = try Segment.parse(boundedBytes(usagePath))
        try check(!latestZero.records.contains { (try? AppUsageProto.decode($0.payload).bundle) == "com.zero.app" },"signed-zero older key does not duplicate")
        try check(try parityStore.readSnapshot().sessions.filter { $0.bundle == "com.zero.app" }.count == 1,"signed-zero older session retained once")
        // Boundary lookup must use ALL segments and stable duplicate ordering.
        let oldLock = lockDir.appendingPathComponent("000-older-lock")
        let oldLockBytes = try Segment(created:-300,size:8192,records:[
            SegmentRecord(timestamp:-50,payload:Data([8,1])),
            SegmentRecord(timestamp:-50,payload:Data([8,0]))
        ]).encoded()
        try privateWrite(oldLockBytes,oldLock)
        func replaceFixture(_ url: URL,_ data: Data) throws {
            try FileManager.default.removeItem(at:url)
            try privateWrite(data,url)
        }
        try replaceFixture(lockPath,Segment(created:-200,size:8192,records:[SegmentRecord(timestamp:500,payload:Data([8,1]))]).encoded())
        let boundaryRequest = ApplyRequest(start:0,end:300,sessions:[StoredSession(bundle:"com.boundary.app",start:60,end:300)],revision:try parityStore.fingerprint())
        let olderPlan = try parityStore.prepareLocks(boundaryRequest)
        let planned = try Segment.parse(olderPlan[0].2)
        try check(planned.records.last(where:{$0.timestamp == 300})?.payload == Data([8,0]),"older segment state restored; stable duplicate last wins")
        try check(try boundedBytes(oldLock) == oldLockBytes,"boundary preparation never rewrites older segments")
        try replaceFixture(lockPath,Segment(created:-200,size:8192,records:[SegmentRecord(timestamp:300,payload:Data([8,0]))]).encoded())
        let exactPlan = try parityStore.prepareLocks(boundaryRequest)
        try check(try Segment.parse(exactPlan[0].2).records.last(where:{$0.timestamp == 300})?.payload == Data([8,0]),"original end boundary wins synthetic closing event")
        try FileManager.default.removeItem(at:oldLock)
        try replaceFixture(lockPath,Segment(created:-200,size:8192,records:[SegmentRecord(timestamp:500,payload:Data([8,1]))]).encoded())
        try rejects("unknown lock boundary fails before backup or writes") { _ = try parityStore.prepareLocks(boundaryRequest) }
        try replaceFixture(lockPath,Segment(created:-200,size:8192,records:[SegmentRecord(timestamp:-50,payload:Data([8,0]))]).encoded())

        // Canonical mappings and explicit absence survive root order changes.
        let emptyCache = cache.appendingPathComponent("empty/nested")
        try FileManager.default.createDirectory(at:emptyCache,withIntermediateDirectories:true)
        try privateWrite(Data("restorable".utf8),cacheFile)
        try check(chmod(cacheFile.path,0o640) == 0 && chmod(emptyCache.path,0o750) == 0,"fixture original nonprivate modes")
        let absentGroup = groups.appendingPathComponent("000-absent-group")
        try FileManager.default.createDirectory(at:absentGroup,withIntermediateDirectories:true)
        let metadataID = try parityStore.backup()
        let metadataFolder = parity.appendingPathComponent("Backups").appendingPathComponent(metadataID)
        let metadataManifest = try JSONDecoder().decode(BackupManifest.self,from:boundedBytes(metadataFolder.appendingPathComponent("manifest.json")))
        let restoredFile = metadataManifest.files.first(where:{$0.originalPath == cacheFile.path})!
        let restoredDir = metadataManifest.directories.first(where:{$0.originalPath == emptyCache.path})!
        try check(restoredFile.mode == 0o640 && restoredDir.mode == 0o750,"original file and directory modes separately persisted")
        try check(metadataManifest.absent.contains(where:{$0.originalPath == absentGroup.appendingPathComponent("Library/com.apple.DeviceActivity/Local").path}),"absent SystemGroup cache path persisted")
        try check(metadataManifest.absent.contains(where:{$0.name == "knowledgeC.db-wal"}) && metadataManifest.absent.contains(where:{$0.name == "knowledgeC.db-shm"}),"absent SQLite WAL and SHM explicitly recorded")
        try check(metadataManifest.directories.contains(where:{$0.originalPath == cache.path}) && restoredFile.originalPath.contains(cache.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().lastPathComponent),"canonical SystemGroup UUID mappings persisted")
        let archivedFile = metadataFolder.appendingPathComponent(restoredFile.name)
        let archivedEmpty = metadataFolder.appendingPathComponent(restoredDir.name)
        try check(try parityStore.metadata(archivedFile).2 == 0o600 && parityStore.metadata(archivedEmpty).2 == 0o700,"private backup modes not confused with original modes")
        try FileManager.default.removeItem(at:archivedEmpty)
        try rejects("missing empty archived directory rejected") { _ = try parityStore.verifyBackup(metadataID) }
        try FileManager.default.createDirectory(at:archivedEmpty,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700,.ownerAccountID:geteuid(),.groupOwnerAccountID:getegid()])
        try check(try parityStore.verifyBackup(metadataID) == metadataManifest.revision,"recreated private empty directory verified")
        try check(chmod(archivedEmpty.path,0o755) == 0,"alter private directory mode")
        try rejects("insecure archived directory mode rejected") { _ = try parityStore.verifyBackup(metadataID) }
        _ = chmod(archivedEmpty.path,0o700)
        try FileManager.default.removeItem(at:archivedEmpty)
        try privateWrite(Data(),archivedEmpty)
        try rejects("directory replaced with regular file rejected") { _ = try parityStore.verifyBackup(metadataID) }
        try FileManager.default.removeItem(at:archivedEmpty)
        try FileManager.default.createDirectory(at:archivedEmpty,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700,.ownerAccountID:geteuid(),.groupOwnerAccountID:getegid()])
        _ = chmod(archivedFile.path,0o644)
        try rejects("insecure archived file mode rejected") { _ = try parityStore.verifyBackup(metadataID) }
        _ = chmod(archivedFile.path,0o600)
        let groupCount = getgroups(0,nil)
        var groupsForTest = [gid_t](repeating:0,count:Int(groupCount))
        let gotGroups = groupsForTest.withUnsafeMutableBufferPointer { getgroups(groupCount,$0.baseAddress) }
        try check(gotGroups > 0,"fixture supplementary groups available")
        if let alternateGID = groupsForTest.first(where: { $0 != getegid() }) {
            try check(chown(archivedFile.path,geteuid(),alternateGID) == 0,"fixture alternate file ownership")
            try rejects("incorrect archived file group owner rejected") { _ = try parityStore.verifyBackup(metadataID) }
            _ = chown(archivedFile.path,geteuid(),getegid())
            try check(chown(archivedEmpty.path,geteuid(),alternateGID) == 0,"fixture alternate directory ownership")
            try rejects("incorrect archived directory group owner rejected") { _ = try parityStore.verifyBackup(metadataID) }
            _ = chown(archivedEmpty.path,geteuid(),getegid())
        }
        try check(restoredFile.uid == parityStore.metadata(cacheFile).0 && restoredFile.gid == parityStore.metadata(cacheFile).1 && restoredDir.uid == parityStore.metadata(emptyCache).0 && restoredDir.gid == parityStore.metadata(emptyCache).1,"original uid gid metadata independently retained")
        let extra = metadataFolder.appendingPathComponent(restoredDir.name+"/unexpected")
        try privateWrite(Data(),extra)
        try rejects("unexpected contents in formerly empty directory rejected") { _ = try parityStore.verifyBackup(metadataID) }
        try FileManager.default.removeItem(at:extra)
        let absentWAL = metadataFolder.appendingPathComponent("knowledgeC.db-wal")
        try privateWrite(Data(),absentWAL)
        try rejects("explicit absent WAL unexpectedly present rejected") { _ = try parityStore.verifyBackup(metadataID) }
        try FileManager.default.removeItem(at:absentWAL)
        try check(try parityStore.verifyBackup(metadataID) == metadataManifest.revision,"backup verified again after fixture tampering repaired")
        let beforeRename = try parityStore.fingerprint()
        let renamedGroup = groups.appendingPathComponent("renamed-system-group")
        let originalGroup = cache.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.moveItem(at:originalGroup,to:renamedGroup)
        try check(try parityStore.fingerprint() != beforeRename,"revision binds original SystemGroup mapping not cache alias alone")
        try FileManager.default.moveItem(at:renamedGroup,to:originalGroup)
        let beforeAbsentChange = try parityStore.fingerprint()
        try FileManager.default.removeItem(at:absentGroup)
        try check(try parityStore.fingerprint() != beforeAbsentChange,"revision binds absent cache paths")

        // Real active WAL fixture. New usage row exists ONLY in the WAL while a
        // writer remains open. Source sidecars, modes, and timestamps must not
        // change during read, preparation, backup or archive verification.
        var walWriter: OpaquePointer?
        try check(sqlite3_open(parityDB.path,&walWriter) == SQLITE_OK,"WAL writer fixture")
        defer { sqlite3_close(walWriter) }
        try check(sqlite3_exec(walWriter,"PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; INSERT INTO ZOBJECT (Z_ENT,Z_OPT,ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING,ZCREATIONDATE) VALUES (43,1,'/app/usage',700,900,'com.wal.only',700);",nil,nil,nil) == SQLITE_OK,"uncheckpointed WAL-only usage row")
        func sqliteState(_ source: URL) throws -> [String:String] {
            var out: [String:String] = [:]
            for suffix in sqliteSuffixes {
                let url = URL(fileURLWithPath:source.path+suffix)
                var info = stat()
                if lstat(url.path,&info) == 0 {
                    let (hash,size) = try hashFile(url)
                    out[suffix] = "\(hash)|\(size)|\(info.st_uid)|\(info.st_gid)|\(info.st_mode)|\(info.st_mtimespec.tv_sec)|\(info.st_mtimespec.tv_nsec)|\(info.st_ctimespec.tv_sec)|\(info.st_ctimespec.tv_nsec)"
                } else { out[suffix] = "absent" }
            }
            return out
        }
        let walBefore = try sqliteState(parityDB)
        try check(walBefore["-wal"] != "absent" && walBefore["-shm"] != "absent","active WAL and SHM exist")
        do {
            let readOnly = try KnowledgeDatabase(parityDB)
            try check(try readOnly.sessions(start:600,end:1000).contains(StoredSession(bundle:"com.wal.only",start:700,end:900)),"private snapshot retains uncheckpointed WAL semantics")
        }
        _ = try parityStore.readSnapshot()
        _ = try parityStore.prepareLocks(boundaryRequest)
        try check(try sqliteState(parityDB) == walBefore,"all source SQLite bytes modes timestamps unchanged before verified backup")
        let beforePrepCalls = calls.count
        let beforePrepUsage = try boundedBytes(usagePath)
        let beforePrepLock = try boundedBytes(lockPath)
        var stoppedBeforeVerification = false
        parityStore.duringBackup = { throw StorageFailure("fixture_stop","Stop after preparation, before backup verification") }
        let prepRequest = ApplyRequest(start:0,end:300,sessions:[StoredSession(bundle:"com.wal.edit",start:60,end:180)],revision:try parityStore.fingerprint())
        do { _ = try parityStore.applyLegacyFixtures(prepRequest) } catch let error as StorageFailure { stoppedBeforeVerification = error.code == "fixture_stop" }
        parityStore.duringBackup = nil
        try check(stoppedBeforeVerification,"apply preparation exercised then stopped before verified backup")
        try check(try sqliteState(parityDB) == walBefore,"apply preparation and preverification backup leave original SQLite sidecars unchanged")
        try check(try boundedBytes(usagePath) == beforePrepUsage && boundedBytes(lockPath) == beforePrepLock && calls.count == beforePrepCalls && FileManager.default.fileExists(atPath:cacheFile.path),"preverification failure leaves usage locks cache and refresh untouched")
        let walID = try parityStore.backup()
        try check(try sqliteState(parityDB) == walBefore,"backup creates no source SQLite changes")
        let walFolder = parity.appendingPathComponent("Backups").appendingPathComponent(walID)
        let archivedDB = walFolder.appendingPathComponent("knowledgeC.db")
        let archivedBefore = try sqliteState(archivedDB)
        _ = try parityStore.verifyBackup(walID)
        _ = try parityStore.verifyBackup(walID)
        do {
            let archivedRead = try KnowledgeDatabase(archivedDB)
            try check(try archivedRead.sessions(start:600,end:1000).contains(StoredSession(bundle:"com.wal.only",start:700,end:900)),"verified backup contains a consistent WAL-aware database")
        }
        try check(try sqliteState(archivedDB) == archivedBefore,"repeated verification never mutates archived database sidecars")
        try check(try sqliteState(parityDB) == walBefore,"verified backup and queries never mutate original SQLite sidecars")

        let activeWALSnapshot = try parityStore.readSnapshot()
        let activeWALRequest = ApplyRequest(start:0,end:300,sessions:[StoredSession(bundle:"com.wal.applied",start:60,end:180)],revision:activeWALSnapshot.revision)
        let activeWALResult = try parityStore.applyLegacyFixtures(activeWALRequest)
        try check(activeWALResult.ok,"active WAL apply succeeds only after fresh verified backup")
        let activeWALArchive = parity.appendingPathComponent("Backups").appendingPathComponent(activeWALResult.details["backupID"]!)
        do {
            let preWrite = try KnowledgeDatabase(activeWALArchive.appendingPathComponent("knowledgeC.db"))
            try check(try !preWrite.sessions(start:0,end:300).contains(where: { $0.bundle == "com.wal.applied" }),"active WAL apply backup retains original prewrite rows")
        }
        try check(sqlite3_wal_checkpoint_v2(walWriter,nil,SQLITE_CHECKPOINT_TRUNCATE,nil,nil) == SQLITE_OK,"explicitly checkpoint fixture before absent-sidecar case")
        try check(sqlite3_close(walWriter) == SQLITE_OK,"close checkpointed WAL fixture")
        walWriter = nil
        for suffix in ["-wal","-shm"] {
            let sidecar = URL(fileURLWithPath:parityDB.path+suffix)
            if FileManager.default.fileExists(atPath:sidecar.path) { try FileManager.default.removeItem(at:sidecar) }
        }
        try check(!FileManager.default.fileExists(atPath:parityDB.path+"-wal") && !FileManager.default.fileExists(atPath:parityDB.path+"-shm"),"closed WAL fixture genuinely has absent sidecars")
        let closedWALSnapshot = try parityStore.readSnapshot()
        let closedWALRequest = ApplyRequest(start:0,end:300,sessions:[StoredSession(bundle:"com.wal.closed",start:60,end:180)],revision:closedWALSnapshot.revision)
        try check(try parityStore.applyLegacyFixtures(closedWALRequest).ok,"WAL-mode database with initially absent sidecars applies after verified absence backup")
        // Full standalone Gemini route: both Biome streams plus knowledgeC rewrite.
        do {
            let db = try KnowledgeDatabase(parityDB,writable:true)
            try db.execute("ALTER TABLE Z_PRIMARYKEY ADD COLUMN Z_SUPER INTEGER DEFAULT 1; ALTER TABLE Z_PRIMARYKEY ADD COLUMN Z_MAX INTEGER DEFAULT 0; INSERT INTO Z_PRIMARYKEY (Z_ENT,Z_NAME,Z_SUPER,Z_MAX) VALUES(1,'Object',0,0)")
            for column in KnowledgeDatabase.geminiColumns where column != "ZVALUEDOUBLE" {
                try db.execute("ALTER TABLE ZOBJECT ADD COLUMN \(column) \(column == "ZUUID" ? "TEXT" : "NUMERIC")")
            }
        }
        let ambiguousRevision = try parityStore.fingerprint()
        try rejects("shipping route rejects older overlapping segment before mutation") {
            _ = try parityStore.apply(ApplyRequest(start:0,end:300,sessions:[],revision:ambiguousRevision))
        }
        try check(try parityStore.fingerprint() == ambiguousRevision,"ambiguous plan leaves sources unchanged")
        try FileManager.default.removeItem(at:zeroOlderPath)
        let backlightDir = parity.appendingPathComponent("backlight")
        try FileManager.default.createDirectory(at:backlightDir,withIntermediateDirectories:false)
        let backlightPath = backlightDir.appendingPathComponent("native-display")
        try privateWrite(Segment(created:-200,size:8192,records:[SegmentRecord(timestamp:-100,payload:NativeAggregates.backlightPayload(-100,true))]).encoded(),backlightPath)
        let fullStore = NativeStorage(database:parityDB,stream:usageDir,backups:parity.appendingPathComponent("Backups"),lockStream:lockDir,backlightStream:backlightDir,groupRoot:groups,runner:{ calls.append($0) })
        try AppTotalFixtures.create(cache)
        let absentDailyPath = cache.appendingPathComponent("Daily/ActivitySegments/0.0.plist")
        try FileManager.default.removeItem(at:absentDailyPath)
        let absentDailyRevision = try fullStore.fingerprint()
        let absentDailyBackup = try fullStore.backup()
        let absentArchive = parity.appendingPathComponent("Backups").appendingPathComponent(absentDailyBackup)
        let absentManifest = try JSONDecoder().decode(BackupManifest.self,from:boundedBytes(absentArchive.appendingPathComponent("manifest.json")))
        try check(absentManifest.absent.contains { $0.originalPath == absentDailyPath.path },
                  "missing Daily is explicitly archived as absence before creation")
        try check(try fullStore.verifyBackup(absentDailyBackup) == absentDailyRevision,
                  "missing Daily existing verified backup retains exact source revision")
        try rejects("production missing Daily rejects before writes") {
            _ = try fullStore.prepareAppTotals(ApplyRequest(start:0,end:86400,sessions:[],revision:absentDailyRevision))
        }
        try check(try fullStore.fingerprint() == absentDailyRevision,"missing Daily leaves exact source revision")
        let hourTemplate = try NativeAppTotals.SegmentValue(boundedBytes(cache.appendingPathComponent("Hourly/ActivitySegments/0.0.plist")))
        let emptyLegacy = try NativeAppTotals.synthesized(
            NativeAppTotals.blank(hourTemplate,start:0,duration:86400),totals:[:],catalog:NativeAppTotals.apps(hourTemplate.value))
        try privateWrite(emptyLegacy,absentDailyPath)
        var provenanceCode = ""
        do { _ = try fullStore.prepareAppTotals(ApplyRequest(start:0,end:86400,sessions:[],revision:absentDailyRevision)) }
        catch let error as StorageFailure { provenanceCode = error.code }
        try check(provenanceCode == "untrusted_baseline","verified backup plus exact legacy synthetic output rejected specifically for provenance")
        try check(try boundedBytes(absentDailyPath) == emptyLegacy,"legacy detection does not repair or write usage")
        try FileManager.default.removeItem(at:absentDailyPath)
        try privateWrite(AppTotalFixtures.bytes(AppTotalFixtures.document(start:0,duration:86400)),absentDailyPath)
        try check(try fullStore.prepareAppTotals(ApplyRequest(start:0,end:86400,sessions:[],revision:absentDailyRevision)).count == 29,
            "genuine regenerated native baseline not blanket rejected by historical absence archive")
        // Restore all cache fixtures for independent legacy tests below.
        try FileManager.default.removeItem(at:cache)
        try AppTotalFixtures.create(cache)
        // Both absent granularities, including metadata, are explicitly bound
        // to the verified CURRENT backup before any exclusive cache creation.
        let bothDaily = cache.appendingPathComponent("Daily/ActivitySegments/0.0.plist")
        let bothWeekly = cache.appendingPathComponent("Weekly/ActivitySegments/0.0.plist")
        let dailyMetadata = cache.appendingPathComponent("Daily/Metadata.plist")
        let weeklyMetadata = cache.appendingPathComponent("Weekly/Metadata.plist")
        for path in [bothDaily,bothWeekly,dailyMetadata,weeklyMetadata] { try FileManager.default.removeItem(at:path) }
        let hmetaPath = cache.appendingPathComponent("Hourly/Metadata.plist")
        let savedHmeta = try boundedBytes(hmetaPath)
        var hmetaDoc = try PropertyListSerialization.propertyList(from:savedHmeta,format:nil) as! [String:Any]
        var hmetaValue = hmetaDoc["value"] as! [String:Any]
        hmetaValue.removeValue(forKey:"untouched"); hmetaDoc["value"] = hmetaValue
        try fullStore.writeExisting(hmetaPath,original:savedHmeta,replacement:AppTotalFixtures.bytes(hmetaDoc))
        let bothRevision = try fullStore.fingerprint()
        let bothBackup = try fullStore.backup()
        let bothArchive = parity.appendingPathComponent("Backups").appendingPathComponent(bothBackup)
        let bothManifest = try JSONDecoder().decode(BackupManifest.self,from:boundedBytes(bothArchive.appendingPathComponent("manifest.json")))
        try check([bothDaily,bothWeekly,dailyMetadata,weeklyMetadata].allSatisfy { path in
            bothManifest.absent.contains { $0.originalPath == path.path }
        }, "both missing records and both missing metadata explicitly archived as absence")
        try check(try fullStore.verifyBackup(bothBackup) == bothRevision, "both-missing backup independently verified")
        try rejects("production missing Weekly rejects unknown history instead of zero filling") {
            _ = try fullStore.prepareAppTotals(ApplyRequest(start:0,end:86400,sessions:[],revision:bothRevision))
        }
        let archiveCount = try FileManager.default.contentsOfDirectory(atPath:fullStore.backups.path).count
        let noUsageBefore = try boundedBytes(usagePath), noLightBefore = try boundedBytes(backlightPath)
        try rejects("shipping Apply missing Weekly fails before backup or any source writes") {
            _ = try fullStore.apply(ApplyRequest(start:0,end:86400,sessions:[],revision:bothRevision))
        }
        try check(try FileManager.default.contentsOfDirectory(atPath:fullStore.backups.path).count == archiveCount,
            "unknown history shipping Apply creates no backup")
        try check(try boundedBytes(usagePath) == noUsageBefore && boundedBytes(backlightPath) == noLightBefore,
            "unknown history shipping Apply leaves stream bytes unchanged")
        try check(try fullStore.fingerprint() == bothRevision,"both missing no source writes")
        try check(try fullStore.verifyBackup(bothBackup) == bothRevision,"absence archive remains verified")
        try FileManager.default.removeItem(at:cache)
        try AppTotalFixtures.create(cache)

        let cloudSource = try AppTotalFixtures.cloud(cache)
        let cloudMissing = [cache.appendingPathComponent("Daily/ActivitySegments/0.0.plist"),
            cache.appendingPathComponent("Weekly/ActivitySegments/0.0.plist"),
            cache.appendingPathComponent("Daily/Metadata.plist"),cache.appendingPathComponent("Weekly/Metadata.plist")]
        for path in cloudMissing { try FileManager.default.removeItem(at:path) }
        let cloudRevision = try fullStore.fingerprint()
        let cloudRequest = ApplyRequest(start:0,end:86400,sessions:[
            StoredSession(bundle:AppTotalFixtures.a,start:3600,end:45000),
            StoredSession(bundle:AppTotalFixtures.b,start:3600,end:45000)],revision:cloudRevision)
        let cloudPlan = try fullStore.prepareAppTotals(cloudRequest,now:Date(timeIntervalSinceReferenceDate:1000))
        try check(try fullStore.fingerprint() == cloudRevision,"production Cloud planning binds source and stays read-only")
        let cloudBackup = try fullStore.backup()
        let cloudArchive = fullStore.backups.appendingPathComponent(cloudBackup)
        let cloudManifest = try JSONDecoder().decode(BackupManifest.self,from:boundedBytes(cloudArchive.appendingPathComponent("manifest.json")))
        try check(try fullStore.verifyBackup(cloudBackup) == cloudRevision,"Cloud source and Local absence backup SHA independently verified")
        try check(cloudMissing.allSatisfy { path in cloudManifest.absent.contains { $0.originalPath == path.path } },
            "Cloud promotion archives both Local records and metadata absences")
        try check(cloudManifest.files.contains { $0.originalPath == cloudSource.appendingPathComponent("Daily/ActivitySegments/0.0.plist").path } &&
            cloudManifest.files.contains { $0.originalPath.hasSuffix("/LocalDeviceIdentifier.plist") },
            "verified backup binds source Cloud native data and Local device identity")
        let cloudMeta = cloudSource.appendingPathComponent("Daily/Metadata.plist")
        let cloudMetaBefore = try boundedBytes(cloudMeta)
        var cloudDoc = try PropertyListSerialization.propertyList(from:cloudMetaBefore,format:nil) as! [String:Any]
        var cloudValue = cloudDoc["value"] as! [String:Any]; cloudValue["lastUpdatedDate"] = Date(timeIntervalSinceReferenceDate:50)
        cloudDoc["value"] = cloudValue
        try fullStore.writeExisting(cloudMeta,original:cloudMetaBefore,replacement:AppTotalFixtures.bytes(cloudDoc))
        try check(try fullStore.fingerprint() != cloudRevision,"Cloud source mutation changes production transaction revision")
        try fullStore.writeExisting(cloudMeta,original:boundedBytes(cloudMeta),replacement:cloudMetaBefore)
        for plan in cloudPlan { try fullStore.writeAppTotal(plan) } // disposable fixture only
        try check(try NativeAppTotals.seconds(NativeAppTotals.SegmentValue(boundedBytes(cloudMissing[0])).value["totalActivityDuration"]) == 82800,
            "production fixture writes overlapping 11.5h plus 11.5h as 23h")
        try check(try fullStore.verifyBackup(cloudBackup) == cloudRevision,"verified archive immutable after fixture-only promotion")
        // Restore exact archived presence/absence only inside this disposable
        // fixture. No production restore API or real-device writes are invoked.
        let oldPaths = Set(cloudManifest.files.map(\.originalPath))
        for plan in cloudPlan where !oldPaths.contains(plan.path.path) {
            if FileManager.default.fileExists(atPath:plan.path.path) { try FileManager.default.removeItem(at:plan.path) }
        }
        for file in cloudManifest.files where file.originalPath.hasPrefix(cache.path+"/") {
            let target = URL(fileURLWithPath:file.originalPath)
            let saved = try boundedBytes(cloudArchive.appendingPathComponent(file.name))
            if FileManager.default.fileExists(atPath:target.path) {
                try fullStore.writeExisting(target,original:boundedBytes(target),replacement:saved)
            } else { try privateWrite(saved,target) }
        }
        try check(cloudMissing.allSatisfy { !FileManager.default.fileExists(atPath:$0.path) },
            "fixture restoration reinstates original Local absences rather than zero baselines")
        try check(try fullStore.fingerprint() == cloudRevision,"fixture restoration returns exact full source revision including Cloud")
        try FileManager.default.removeItem(at:cache)
        try FileManager.default.removeItem(at:cloudSource.deletingLastPathComponent().deletingLastPathComponent())
        try FileManager.default.removeItem(at:cache.deletingLastPathComponent().appendingPathComponent("LocalDeviceIdentifier.plist"))
        try AppTotalFixtures.create(cache)
        // Match the live blocker: retained native events begin AFTER the
        // selected edit. Planning must synthesize a closed missing boundary,
        // while production Apply still verifies a current backup before writes.
        let laterNative = [
            SegmentRecord(timestamp:90000,flag:77,payload:try NativeAggregates.backlightPayload(90000,true)),
            SegmentRecord(timestamp:90100,flag:91,payload:try NativeAggregates.backlightPayload(90100,false))]
        let missingBoundaryBytes = try Segment(created:-200,size:8192,records:laterNative).encoded()
        try fullStore.writeExisting(backlightPath,original:boundedBytes(backlightPath),replacement:missingBoundaryBytes)
        let missingRevision = try fullStore.fingerprint()
        let missingPlan = try fullStore.prepareBacklight(ApplyRequest(start:0,end:86400,sessions:[],revision:missingRevision))
        try check(missingPlan.count == 1 && missingPlan[0].1 == missingBoundaryBytes,
                  "production planner accepts actual missing-boundary shape without changing original")
        try check(try fullStore.fingerprint() == missingRevision,"missing-boundary preparation is read only")
        let beforeMissingUsage = try boundedBytes(usagePath), beforeMissingLocks = try boundedBytes(lockPath)
        let beforeMissingDB = try sqliteState(parityDB), beforeMissingCalls = calls.count
        let beforeMissingArchives = Set(try FileManager.default.contentsOfDirectory(atPath:fullStore.backups.path))
        fullStore.afterBackup = {
            let folders = try FileManager.default.contentsOfDirectory(at:fullStore.backups,includingPropertiesForKeys:nil)
            for folder in folders where !beforeMissingArchives.contains(folder.lastPathComponent) {
                let archive = folder.appendingPathComponent("backlight-native-display")
                guard FileManager.default.fileExists(atPath:archive.path) else { continue }
                var bytes = try boundedBytes(archive)
                bytes[40] ^= 1
                let fd = open(archive.path,O_WRONLY)
                _ = bytes.withUnsafeBytes { pwrite(fd,$0.baseAddress,$0.count,0) }; close(fd)
            }
        }
        try rejects("missing-boundary Apply refuses unverified corrupt backup before any writes") {
            _ = try fullStore.apply(ApplyRequest(start:0,end:86400,sessions:[],revision:missingRevision))
        }
        fullStore.afterBackup = nil
        try check(try fullStore.fingerprint() == missingRevision &&
                  boundedBytes(usagePath) == beforeMissingUsage && boundedBytes(lockPath) == beforeMissingLocks &&
                  sqliteState(parityDB) == beforeMissingDB && calls.count == beforeMissingCalls,
                  "missing-boundary synthesis cannot write or refresh before verified backup")
        let preBacklightRace = try boundedBytes(backlightPath)
        let preUsageRace = try boundedBytes(usagePath)
        let raceRevision = try fullStore.fingerprint()
        fullStore.afterBackup = {
            var changed = try Segment.parse(boundedBytes(backlightPath))
            changed.reserved = 17
            let f = open(backlightPath.path,O_WRONLY)
            let bytes = try changed.encoded()
            _ = bytes.withUnsafeBytes { pwrite(f,$0.baseAddress,$0.count,0) }; close(f)
        }
        try rejects("backlight revision race stops all apply writes") {
            _ = try fullStore.apply(ApplyRequest(start:0,end:86400,sessions:[],revision:raceRevision))
        }
        fullStore.afterBackup = nil
        try check(try boundedBytes(usagePath) == preUsageRace,"backlight race leaves usage untouched")
        try fullStore.writeExisting(backlightPath,original:boundedBytes(backlightPath),replacement:preBacklightRace)
        let cacheRacePath = cache.appendingPathComponent("Daily/ActivitySegments/0.0.plist")
        let cacheRaceOld = try boundedBytes(cacheRacePath)
        let cacheRaceRevision = try fullStore.fingerprint()
        let beforeCacheRaceUsage = try boundedBytes(usagePath)
        fullStore.afterBackup = {
            let fd = open(cacheRacePath.path,O_WRONLY)
            var byte: UInt8 = 0
            _ = pwrite(fd,&byte,1,0); close(fd)
        }
        try rejects("cache revision race stops all apply writes") {
            _ = try fullStore.apply(ApplyRequest(start:0,end:86400,sessions:[],revision:cacheRaceRevision))
        }
        fullStore.afterBackup = nil
        try check(try boundedBytes(usagePath) == beforeCacheRaceUsage,"cache race leaves usage untouched")
        try fullStore.writeExisting(cacheRacePath,original:boundedBytes(cacheRacePath),replacement:cacheRaceOld)
        let geminiDBBefore = try sqliteState(parityDB)
        let geminiRevision = try fullStore.fingerprint()
        let geminiReply = try fullStore.apply(ApplyRequest(start:0,end:86400,sessions:[StoredSession(bundle:"com.apple.mobilesafari",start:60,end:180)],revision:geminiRevision))
        try check(geminiReply.ok && geminiReply.details["writer"] == "gemini_ios_full_native","shipping route selected")
        let nativeDay = try NativeAppTotals.SegmentValue(boundedBytes(cache.appendingPathComponent("Daily/ActivitySegments/0.0.plist")))
        try check(try NativeAppTotals.seconds(nativeDay.value["totalActivityDuration"]) == 120,"shipping Apply writes exact apps-only native total")
        try check(geminiReply.details["totalPolicy"] == "sum_apps_including_overlap","shipping total policy")
        let metadata = try PropertyListSerialization.propertyList(from:boundedBytes(cache.appendingPathComponent("Hourly/Metadata.plist")),format:nil) as! [String:Any]
        try check(((metadata["value"] as! [String:Any])["lastUpdatedDate"] as! Date) > Date(),"shipping Apply freezes native refresh in future")
        try check(try sqliteState(parityDB) != geminiDBBefore,"full Gemini route rewrites knowledgeC")
        do {
            let db = try KnowledgeDatabase(parityDB)
            var inserted = 0, identifiers = Set<String>()
            try db.query("SELECT ZSTREAMNAME,ZVALUESTRING,ZSTARTDATE,ZENDDATE,ZUUID,ZSECONDSFROMGMT,ZVALUECLASS,ZSTARTDAYOFWEEK,ZENDDAYOFWEEK,ZSTARTSECONDOFDAY,ZENDSECONDOFDAY FROM ZOBJECT WHERE ZSTARTDATE=60 AND ZENDDATE=180") { row in
                inserted += 1
                let begin = Date(timeIntervalSinceReferenceDate:60), end = Date(timeIntervalSinceReferenceDate:180)
                let cal = Calendar.current
                try check(sqlite3_column_int(row,5) == TimeZone.current.secondsFromGMT(for:begin),"selected date timezone metadata")
                try check(sqlite3_column_int(row,7) == (cal.component(.weekday,from:begin)+5)%7 && sqlite3_column_int(row,8) == (cal.component(.weekday,from:end)+5)%7,"selected date weekday metadata")
                try check(sqlite3_column_int(row,9) == Int(60-cal.startOfDay(for:begin).timeIntervalSinceReferenceDate) && sqlite3_column_int(row,10) == Int(180-cal.startOfDay(for:end).timeIntervalSinceReferenceDate),"selected session clock metadata")
                identifiers.insert(String(cString:sqlite3_column_text(row,4)))
                let stream = String(cString:sqlite3_column_text(row,0))
                if stream == "/app/usage" {
                    try check(String(cString:sqlite3_column_text(row,1)) == "com.apple.mobilesafari","selected bundle in full SQL")
                    try check(sqlite3_column_int(row,6) == 1,"usage class preserved")
                } else { try check(stream == "/device/isLocked" && sqlite3_column_int(row,6) == 2,"unlocked row full metadata") }
            }
            try check(inserted == 2 && identifiers.count == 2,"unique per-session usage and lock UUIDs")
        }
        try check(try pairUsage(parityStore.events([usagePath])).contains(StoredSession(bundle:"com.apple.mobilesafari",start:60,end:180)),"shipping Gemini route writes requested Safari session")
        try check(calls.last == ["gemini-sync-or-open"],"fixed original sync/open refresh requested")
        try check(try fullStore.verifyBackup(geminiReply.details["backupID"]!) == geminiRevision,"shipping Gemini route mandatory backup verified")
        let nativeManifest = try JSONDecoder().decode(BackupManifest.self,from:boundedBytes(parity.appendingPathComponent("Backups").appendingPathComponent(geminiReply.details["backupID"]!).appendingPathComponent("manifest.json")))
        try check(nativeManifest.files.contains { $0.name == "backlight-native-display" },"backlight independently archived")
        let cachedHours = nativeManifest.files.filter { $0.name.contains("/Hourly/ActivitySegments/") }
        try check(cachedHours.count == 1,"prewrite backup inventory records only original hour, not 23 newly created buckets")
        guard let originalDaily = nativeManifest.files.first(where: { $0.name.hasSuffix("/Daily/ActivitySegments/0.0.plist") }) else {
            throw StorageFailure("test_failed","Daily cache missing from verified backup")
        }
        let nativeArchive = parity.appendingPathComponent("Backups").appendingPathComponent(geminiReply.details["backupID"]!)
        let cachedDaily = try NativeAppTotals.SegmentValue(boundedBytes(nativeArchive.appendingPathComponent(originalDaily.name)))
        try check(try NativeAppTotals.seconds(cachedDaily.value["totalActivityDuration"]) == 999999,"verified backup retains old native cache bytes before exact sum")

        try check(try fullStore.verifyBackup(geminiReply.details["backupID"]!) == geminiRevision,"backlight archive verified with original checksum and metadata")
        let archivedBacklight = parity.appendingPathComponent("Backups").appendingPathComponent(geminiReply.details["backupID"]!).appendingPathComponent("backlight-native-display")
        let privateMode = try fullStore.metadata(archivedBacklight)
        try check(privateMode.2 == 0o600 && privateMode.0 == geteuid(),"backlight copy private metadata")
        let archiveBytes = try boundedBytes(archivedBacklight)
        var damaged = archiveBytes; damaged[40] ^= 1
        let archiveFD = open(archivedBacklight.path,O_WRONLY)
        _ = damaged.withUnsafeBytes { pwrite(archiveFD,$0.baseAddress,$0.count,0) }; close(archiveFD)
        try rejects("backlight archive corruption rejected") { _ = try fullStore.verifyBackup(geminiReply.details["backupID"]!) }
        let restoreFD = open(archivedBacklight.path,O_WRONLY)
        _ = archiveBytes.withUnsafeBytes { pwrite(restoreFD,$0.baseAddress,$0.count,0) }; close(restoreFD)
        let nativeBacklight = try Segment.parse(boundedBytes(backlightPath))
        try check(nativeBacklight.records.filter { $0.timestamp >= 90000 }.map(\.payload) == laterNative.map(\.payload) &&
                  nativeBacklight.records.filter { $0.timestamp >= 90000 }.map(\.flag) == laterNative.map(\.flag),
                  "shipping missing-boundary Apply preserves outside native records exactly")
        try check(archiveBytes == missingBoundaryBytes,"verified prewrite archive retains missing-boundary original bytes")
        try check(nativeBacklight.records.contains { $0.timestamp == 86400 && (try? NativeAggregates.backlightState($0)) == false },
                  "shipping missing-boundary Apply closes synthesized interval")
        try check(nativeBacklight.records.contains { $0.timestamp == 60 && (try? NativeAggregates.backlightState($0)) == true },"native backlight session on")
        _ = try parityStore.fingerprint() // Patched Local roots remain fingerprinted and backed up.
        let response = try StorageProtocol.handle(HelperRequest(op:.read),storage:store)
        try check(response.ok && response.details["snapshot"] != nil,"read protocol")
        do {
            let change = try KnowledgeDatabase(dbURL,writable:true)
            try change.execute("DELETE FROM Z_PRIMARYKEY")
        }
        try rejects("missing entity metadata fails closed") { _ = try store.readSnapshot() }
        print("PASS native storage \(count) checks, temporary synthetic stores only")
    }
}
