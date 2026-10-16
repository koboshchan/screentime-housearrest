import Foundation
import SQLite3
import CryptoKit
import Darwin

public struct StorageSnapshot: Codable {
    public var sessions: [StoredSession]
    public var revision: String
    public var warnings: [String]
}
public struct ApplyRequest: Codable {
    public var start: Double
    public var end: Double
    public var sessions: [StoredSession]
    public var revision: String
    public var overrideSourceChanges: Bool
    public init(start: Double, end: Double, sessions: [StoredSession], revision: String, overrideSourceChanges: Bool = false) {
        self.start = start; self.end = end; self.sessions = sessions; self.revision = revision; self.overrideSourceChanges = overrideSourceChanges
    }
}
struct BackupFile: Codable {
    var name: String
    var digest: String
    var size: UInt64
    var uid: UInt32
    var gid: UInt32
    var mode: UInt16
}
struct BackupManifest: Codable {
    var format: Int
    var revision: String
    var files: [BackupFile]
    var directories: [BackupDirectory]
}
struct BackupDirectory: Codable { var name: String; var uid: UInt32; var gid: UInt32; var mode: UInt16 }
func rejectLinks(_ url: URL) throws {
    let path = url.path
    try requireStorage(path.hasPrefix("/"), "Nonabsolute internal path.")
    var current = ""
    for part in path.split(separator:"/") {
        current += "/" + part
        var info = stat()
        if lstat(current,&info) == 0 {
            try requireStorage(info.st_mode & S_IFMT != S_IFLNK, "Symbolic links are not accepted.", "unsafe_path")
        } else if errno != ENOENT { throw StorageFailure("read_failed", "Cannot inspect storage path.") }
    }
}
func regularFD(_ url: URL, flags: Int32 = O_RDONLY) throws -> Int32 {
    try rejectLinks(url)
    let fd = open(url.path,flags | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw StorageFailure("read_failed", "Cannot open storage file (errno \(errno)).") }
    var info = stat()
    guard fstat(fd,&info) == 0, info.st_mode & S_IFMT == S_IFREG else {
        close(fd); throw StorageFailure("unsafe_path", "Source is not a regular file.")
    }
    return fd
}
func hashFile(_ url: URL, limit: UInt64 = 2_147_483_648) throws -> (String,UInt64) {
    let fd = try regularFD(url); defer { close(fd) }
    var digest = SHA256(), total: UInt64 = 0, buffer = [UInt8](repeating:0,count:1024*1024)
    var before = stat(); try requireStorage(fstat(fd,&before) == 0,"Cannot inspect file.")
    while true {
        let count = read(fd,&buffer,buffer.count)
        if count == 0 { break }
        try requireStorage(count > 0,"Cannot hash file.", "read_failed")
        total += UInt64(count)
        try requireStorage(total <= limit,"Storage file exceeds supported size.","size_limit")
        digest.update(data:Data(buffer[0..<count]))
    }
    var after = stat(); try requireStorage(fstat(fd,&after) == 0,"Cannot inspect file.")
    try requireStorage(before.st_size == after.st_size && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,"Source changed during hash.","concurrent_change")
    return (digest.finalize().map { String(format:"%02x",$0) }.joined(),total)
}
func boundedBytes(_ url: URL, maximum: Int = Segment.maximumSize) throws -> Data {
    let fd = try regularFD(url); defer { close(fd) }
    var info = stat()
    try requireStorage(fstat(fd,&info) == 0 && info.st_size >= 0 && info.st_size <= maximum,"Invalid bounded file size.","size_limit")
    var data = Data(), buffer = [UInt8](repeating:0,count:65536)
    while true {
        let n = read(fd,&buffer,buffer.count)
        if n == 0 { break }
        try requireStorage(n > 0 && data.count + n <= maximum,"Bounded file read failed.","read_failed")
        data.append(contentsOf:buffer[0..<n])
    }
    return data
}
func privateWrite(_ data: Data, _ url: URL) throws {
    try rejectLinks(url)
    let fd = open(url.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
    try requireStorage(fd >= 0,"Cannot create private backup file.","backup_failed")
    defer { close(fd) }
    try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
            let n = write(fd,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
            try requireStorage(n > 0,"Cannot write private file.","backup_failed")
            offset += n
        }
    }
    try requireStorage(fsync(fd) == 0,"Cannot sync backup.","backup_failed")
}
func privateCopy(_ source: URL, _ target: URL) throws {
    let input = try regularFD(source); defer { close(input) }
    try rejectLinks(target)
    let output = open(target.path,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
    try requireStorage(output >= 0,"Cannot create backup.","backup_failed")
    defer { close(output) }
    var buffer = [UInt8](repeating:0,count:1024*1024), total = 0
    while true {
        let n = read(input,&buffer,buffer.count)
        if n == 0 { break }
        try requireStorage(n > 0,"Backup source read failed.","backup_failed")
        total += n; try requireStorage(total <= 2_147_483_648,"Backup source exceeds supported size.","size_limit")
        try buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset < n {
                let count = write(output,raw.baseAddress!.advanced(by:offset),n-offset)
                try requireStorage(count > 0,"Backup write failed.","backup_failed")
                offset += count
            }
        }
    }
    try requireStorage(fsync(output) == 0,"Backup sync failed.","backup_failed")
}
final class KnowledgeDatabase {
    var db: OpaquePointer?
    var usageEntity: Int32 = 0
    init(_ path: URL, writable: Bool = false) throws {
        try rejectLinks(path)
        let fd = try regularFD(path); close(fd)
        let flags = (writable ? SQLITE_OPEN_READWRITE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path.path,&db,flags,nil)
        guard rc == SQLITE_OK else { if let db { sqlite3_close(db) }; db = nil; throw StorageFailure("read_failed","Cannot open knowledgeC database.") }
        sqlite3_busy_timeout(db,2000)
        try execute("PRAGMA trusted_schema=OFF")
        var columns = Set<String>()
        try query("PRAGMA table_info(ZOBJECT)") { statement in
            if let value = sqlite3_column_text(statement,1) { columns.insert(String(cString:value)) }
        }
        try requireStorage(Set(["Z_ENT","Z_OPT","ZSTREAMNAME","ZSTARTDATE","ZENDDATE","ZVALUESTRING","ZCREATIONDATE"]).isSubset(of:columns),"Unsupported knowledgeC schema.","unsupported_schema")
        // Never borrow the macOS entity number. Existing usage rows must agree,
        // and Core Data metadata must identify that concrete entity.
        var entities = Set<Int32>()
        try query("SELECT DISTINCT Z_ENT FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage'") { row in
            try requireStorage(sqlite3_column_type(row,0) == SQLITE_INTEGER,"Usage entity is not an integer.","unsupported_schema")
            entities.insert(sqlite3_column_int(row,0))
        }
        try requireStorage(entities.count == 1,"Cannot unambiguously resolve the usage entity from existing usage rows.","unsupported_schema")
        usageEntity = entities.first!
        try requireStorage(usageEntity > 0,"Invalid usage entity.","unsupported_schema")
        var metadataMatches = 0
        try query("SELECT Z_ENT,Z_NAME FROM Z_PRIMARYKEY") { row in
            if sqlite3_column_int(row,0) == self.usageEntity {
                guard let name = sqlite3_column_text(row,1), !String(cString:name).isEmpty else {
                    throw StorageFailure("unsupported_schema","Usage entity metadata is unnamed.")
                }
                metadataMatches += 1
            }
        }
        try requireStorage(metadataMatches == 1,"Usage entity metadata is missing or ambiguous.","unsupported_schema")
    }
    deinit { if let db { sqlite3_close(db) } }
    func execute(_ sql: String) throws {
        try requireStorage(sqlite3_exec(db,sql,nil,nil,nil) == SQLITE_OK,"knowledgeC SQL operation failed.","database_failed")
    }
    func query(_ sql: String, parameters: [Double] = [], body: (OpaquePointer) throws -> Void) throws {
        var statement: OpaquePointer?
        try requireStorage(sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK,"Cannot prepare knowledgeC query.","unsupported_schema")
        defer { sqlite3_finalize(statement) }
        guard let statement else { throw StorageFailure("database_failed","Missing statement.") }
        for (i,value) in parameters.enumerated() { sqlite3_bind_double(statement,Int32(i+1),value) }
        var rows = 0
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { break }
            try requireStorage(code == SQLITE_ROW,"Cannot read knowledgeC rows.","database_failed")
            rows += 1; try requireStorage(rows <= 1_000_000,"Too many database rows.","size_limit")
            try body(statement)
        }
    }
    func sessions(start: Double, end: Double) throws -> [StoredSession] {
        var out: [StoredSession] = []
        try query("SELECT ZSTARTDATE,ZENDDATE,ZVALUESTRING FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage' AND ZENDDATE>? AND ZSTARTDATE<?",parameters:[start,end]) { row in
            let a = sqlite3_column_double(row,0), b = sqlite3_column_double(row,1)
            try validClock(a); try validClock(b)
            guard let raw = sqlite3_column_text(row,2) else { throw StorageFailure("unsupported_schema","Missing bundle.") }
            out.append(StoredSession(bundle:String(cString:raw),start:a,end:b))
        }
        return out
    }
    func replace(start: Double, end: Double, sessions: [StoredSession]) throws {
        try query("DELETE FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage' AND ZENDDATE>? AND ZSTARTDATE<?",parameters:[start,end]) { _ in }
        for s in sessions {
            var stmt: OpaquePointer?
            try requireStorage(sqlite3_prepare_v2(db,"INSERT INTO ZOBJECT (Z_ENT,Z_OPT,ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUESTRING,ZCREATIONDATE) VALUES (?,1,'/app/usage',?,?,?,?)",-1,&stmt,nil) == SQLITE_OK,"Cannot prepare usage insertion.","unsupported_schema")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt,1,usageEntity); sqlite3_bind_double(stmt,2,s.start); sqlite3_bind_double(stmt,3,s.end)
            let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt,4,s.bundle,-1,transient); sqlite3_bind_double(stmt,5,s.start)
            try requireStorage(sqlite3_step(stmt) == SQLITE_DONE,"Cannot insert usage row.","database_failed")
        }
    }
    func validateLocks() throws {
        var columns = Set<String>()
        try query("PRAGMA table_info(ZOBJECT)") { row in
            if let value = sqlite3_column_text(row,1) { columns.insert(String(cString:value)) }
        }
        try requireStorage(columns.contains("ZVALUEDOUBLE"),"Missing lock value column.","unsupported_schema")
        var entities = Set<Int32>()
        try query("SELECT DISTINCT Z_ENT FROM ZOBJECT WHERE ZSTREAMNAME='/device/isLocked'") { row in
            try requireStorage(sqlite3_column_type(row,0) == SQLITE_INTEGER,"Invalid lock entity.","unsupported_schema")
            entities.insert(sqlite3_column_int(row,0))
        }
        try requireStorage(entities.count == 1 && entities.first! > 0,"Cannot resolve ScreenLocked entity.","unsupported_schema")
        var matches = 0
        try query("SELECT Z_NAME FROM Z_PRIMARYKEY WHERE Z_ENT=\(entities.first!)") { row in
            if let name = sqlite3_column_text(row,0), !String(cString:name).isEmpty { matches += 1 }
        }
        try requireStorage(matches == 1,"Missing ScreenLocked entity metadata.","unsupported_schema")
    }
    func replaceLocks(start: Double, end: Double, sessions: [StoredSession], enabled: Bool) throws {
        guard enabled else { return }
        var entities = Set<Int32>()
        try query("SELECT DISTINCT Z_ENT FROM ZOBJECT WHERE ZSTREAMNAME='/device/isLocked'") { row in entities.insert(sqlite3_column_int(row,0)) }
        try requireStorage(entities.count == 1,"Cannot resolve ScreenLocked entity.","unsupported_schema")
        let entity = entities.first!
        var matches = 0
        try query("SELECT Z_NAME FROM Z_PRIMARYKEY WHERE Z_ENT=\(entity)") { row in
            if let name = sqlite3_column_text(row,0), !String(cString:name).isEmpty { matches += 1 }
        }
        try requireStorage(matches == 1,"Missing ScreenLocked metadata.","unsupported_schema")
        // Preserve overlapping lock rows outside the requested interval.
        var outside: [(Double,Double,Double)] = []
        try query("SELECT ZSTARTDATE,ZENDDATE,ZVALUEDOUBLE FROM ZOBJECT WHERE ZSTREAMNAME='/device/isLocked' AND ZENDDATE>? AND ZSTARTDATE<?",parameters:[start,end]) { row in
            let a = sqlite3_column_double(row,0), b = sqlite3_column_double(row,1), value = sqlite3_column_double(row,2)
            if a < start { outside.append((a,start,value)) }
            if b > end { outside.append((end,b,value)) }
        }
        try query("DELETE FROM ZOBJECT WHERE ZSTREAMNAME='/device/isLocked' AND ZENDDATE>? AND ZSTARTDATE<?",parameters:[start,end]) { _ in }
        var ranges: [(Double,Double)] = []
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            if let last = ranges.last, s.start <= last.1 { ranges[ranges.count-1].1 = max(last.1,s.end) }
            else { ranges.append((s.start,s.end)) }
        }
        var cursor = start, rows = outside
        for (a,b) in ranges {
            if a > cursor { rows.append((cursor,a,1)) }
            rows.append((a,b,0)); cursor = b
        }
        if cursor < end { rows.append((cursor,end,1)) }
        for (a,b,value) in rows {
            try query("INSERT INTO ZOBJECT (Z_ENT,Z_OPT,ZSTREAMNAME,ZSTARTDATE,ZENDDATE,ZVALUEDOUBLE,ZCREATIONDATE) VALUES (\(entity),1,'/device/isLocked',?,?,?,?)",parameters:[a,b,value,a]) { _ in }
        }
    }

}
public final class NativeStorage {
    let database: URL
    let stream: URL
    let backups: URL
    let lockStream: URL?
    let groupRoot: URL?
    let refreshRunner: ([String]) throws -> Void
    #if HOST_STORAGE_TEST
    var afterBackup: (() throws -> Void)?
    var duringBackup: (() throws -> Void)?
    var beforeTransactionWrite: (() throws -> Void)?
    #endif
    public convenience init() {
        self.init(fixedDatabase:URL(fileURLWithPath:"/private/var/mobile/Library/CoreDuet/Knowledge/knowledgeC.db"),
                  stream:URL(fileURLWithPath:"/private/var/mobile/Library/Biome/streams/restricted/ScreenTime.AppUsage/local"),
                  backups:URL(fileURLWithPath:"/private/var/mobile/Library/ScreenTimeEditor/Backups"),
                  lockStream:URL(fileURLWithPath:"/private/var/db/biome/streams/restricted/Device.ScreenLocked/local"),
                  groupRoot:URL(fileURLWithPath:"/private/var/containers/Shared/SystemGroup"),
                  refreshRunner: NativeStorage.refreshProcesses)
    }
    private init(fixedDatabase database: URL, stream: URL, backups: URL, lockStream: URL? = nil, groupRoot: URL? = nil, refreshRunner: @escaping ([String]) throws -> Void = { _ in }) {
        self.database = database; self.stream = stream; self.backups = backups; self.lockStream = lockStream; self.groupRoot = groupRoot; self.refreshRunner = refreshRunner
    }
    #if HOST_STORAGE_TEST
    // Excluded from shipping app/helper. There is no path input in the wire protocol.
    convenience init(database: URL, stream: URL, backups: URL, lockStream: URL? = nil, groupRoot: URL? = nil, runner: @escaping ([String]) throws -> Void = { _ in }) {
        self.init(fixedDatabase:database,stream:stream,backups:backups,lockStream:lockStream,groupRoot:groupRoot,refreshRunner:runner)
    }
    #endif
    func segments() throws -> [URL] {
        try rejectLinks(stream)
        let files = try FileManager.default.contentsOfDirectory(at:stream,includingPropertiesForKeys:nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && !["lock","tombstone"].contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try requireStorage(!files.isEmpty && files.count <= 10000,"No readable AppUsage segments.","read_failed")
        for path in files { let fd = try regularFD(path); close(fd) }
        return files
    }
    static func refreshProcesses(_ names: [String]) throws {
        // Match exact kernel process names and signal directly. No shell, killall
        // executable, launchctl or jailbreak-root path is involved.
        typealias ListPIDs = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
        typealias ProcessName = @convention(c) (Int32, UnsafeMutableRawPointer?, UInt32) -> Int32
        guard let handle = dlopen(nil,RTLD_NOW), let listSymbol = dlsym(handle,"proc_listallpids"),
              let nameSymbol = dlsym(handle,"proc_name") else {
            throw StorageFailure("refresh_failed","Process enumeration unavailable.")
        }
        defer { dlclose(handle) }
        let list = unsafeBitCast(listSymbol,to:ListPIDs.self)
        let name = unsafeBitCast(nameSymbol,to:ProcessName.self)
        let count = list(nil,0)
        try requireStorage(count > 0 && count <= 100000,"Invalid process inventory.","refresh_failed")
        var pids = [Int32](repeating:0,count:Int(count)+1024)
        let actual = pids.withUnsafeMutableBytes { list($0.baseAddress,Int32($0.count)) }
        try requireStorage(actual >= 0 && actual <= pids.count,"Process inventory changed.","refresh_failed")
        for pid in pids.prefix(Int(actual)) where pid > 1 && pid != getpid() {
            var bytes = [CChar](repeating:0,count:1024)
            let length = bytes.withUnsafeMutableBytes { name(pid,$0.baseAddress,UInt32($0.count)) }
            guard length > 0 else { continue }
            let process = String(cString:bytes)
            if names.contains(process) {
                // Recheck exact identity immediately before signalling.
                var again = [CChar](repeating:0,count:1024)
                let checked = again.withUnsafeMutableBytes { name(pid,$0.baseAddress,UInt32($0.count)) }
                try requireStorage(checked > 0 && String(cString:again) == process,"Refresh process changed.","refresh_failed")
                try requireStorage(kill(pid,SIGTERM) == 0 || errno == ESRCH,"Cannot stop UI process.","refresh_failed")
            }
        }
    }
    func lockSegments() throws -> [URL] {
        guard let lockStream else { return [] }
        try rejectLinks(lockStream)
        let result = try FileManager.default.contentsOfDirectory(at:lockStream,includingPropertiesForKeys:nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && !["lock","tombstone"].contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try requireStorage(!result.isEmpty && result.count <= 10000,"No ScreenLocked segments.","unsupported_schema")
        for url in result { _ = try Segment.parse(boundedBytes(url)) }
        return result
    }
    func cacheRoots() throws -> [URL] {
        guard let groupRoot else { return [] }
        try rejectLinks(groupRoot)
        let groups = try FileManager.default.contentsOfDirectory(at:groupRoot,includingPropertiesForKeys:nil)
        try requireStorage(groups.count <= 10000,"Too many shared groups.","size_limit")
        var roots: [URL] = []
        for group in groups {
            try rejectLinks(group)
            let local = group.appendingPathComponent("Library/com.apple.DeviceActivity/Local")
            if FileManager.default.fileExists(atPath:local.path) { try rejectLinks(local); roots.append(local) }
        }
        try requireStorage(!roots.isEmpty,"DeviceActivity Local cache was not found.","unsupported_schema")
        return roots.sorted { $0.path < $1.path }
    }
    func inventory() throws -> (files: [(String,URL)], directories: [(String,URL)]) {
        var files = try segments().map { ("segment-"+$0.lastPathComponent,$0) }
        files += try lockSegments().map { ("lock-"+$0.lastPathComponent,$0) }
        for suffix in ["","-wal","-shm"] {
            let url = URL(fileURLWithPath:database.path+suffix)
            if FileManager.default.fileExists(atPath:url.path) { files.append(("knowledgeC.db"+suffix,url)) }
            else { try requireStorage(suffix != "","knowledgeC missing.","read_failed") }
        }
        var directories: [(String,URL)] = []
        func walk(_ url: URL,_ name: String) throws {
            try rejectLinks(url)
            var st = stat()
            try requireStorage(lstat(url.path,&st) == 0,"Cannot inspect cache.","read_failed")
            if st.st_mode & S_IFMT == S_IFDIR {
                directories.append((name,url))
                for child in try FileManager.default.contentsOfDirectory(at:url,includingPropertiesForKeys:nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    try walk(child,name+"/"+child.lastPathComponent)
                }
            } else {
                try requireStorage(st.st_mode & S_IFMT == S_IFREG && st.st_nlink == 1,"Unsupported cache file.","unsafe_path")
                files.append((name,url))
            }
            try requireStorage(files.count+directories.count <= 30000,"Cache inventory exceeds limit.","size_limit")
        }
        for (i,root) in try cacheRoots().enumerated() { try walk(root,"cache-\(i)") }
        return (files,directories)
    }
    func sources() throws -> [(String,URL)] { try inventory().files }
    func metadata(_ url: URL) throws -> (UInt32,UInt32,UInt16) {
        try rejectLinks(url)
        var st = stat(); try requireStorage(lstat(url.path,&st) == 0,"Cannot inspect metadata.","read_failed")
        return (st.st_uid,st.st_gid,UInt16(st.st_mode & 0o7777))
    }
    public func fingerprint() throws -> String {
        var hash = SHA256()
        for (name,path) in try sources() {
            let (digest,_) = try hashFile(path,limit:name.hasPrefix("segment-") ? UInt64(Segment.maximumSize) : 2_147_483_648)
            let (uid,gid,mode) = try metadata(path)
            hash.update(data:Data((name+"\u{0}"+digest+"|\(uid)|\(gid)|\(mode)\n").utf8))
        }
        for (name,path) in try inventory().directories {
            let (uid,gid,mode) = try metadata(path)
            hash.update(data:Data((name+"|\(uid)|\(gid)|\(mode)\n").utf8))
        }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    func events(_ paths: [URL]) throws -> [UsageEvent] {
        var result: [UsageEvent] = []
        for path in paths {
            let segment = try Segment.parse(boundedBytes(path))
            for record in segment.records where record.state == 1 {
                // Match the original reader: skip undecodable historical payloads;
                // footer timestamps, not protobuf wall clocks, determine the timeline.
                if var event = try? AppUsageProto.decode(record.payload) {
                    event.time = record.timestamp; result.append(event)
                }
            }
        }
        return result
    }
    public func readSnapshot() throws -> StorageSnapshot {
        let before = try fingerprint(), paths = try segments()
        let sessions = try pairUsage(events(paths))
        let db = try KnowledgeDatabase(database)
        if lockStream != nil { try db.validateLocks() }
        _ = try db.sessions(start:-978307200,end:252423993599)
        try requireStorage(try fingerprint() == before,"Source changed while reading.","concurrent_change")
        return StorageSnapshot(sessions:sessions,revision:before,warnings:[
            "Only the latest AppUsage segment is written; older segments remain unchanged.",
            "Unmatched or undecodable historical events are not editable sessions.",
            "Device runtime and cross-device aggregation require device verification."
        ])
    }
    public func backup() throws -> String {
        let revision = try fingerprint()
        try rejectLinks(backups)
        try FileManager.default.createDirectory(at:backups,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let id = UUID().uuidString, folder = backups.appendingPathComponent(id)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var entries: [BackupFile] = []
        for (name,source) in try sources() {
            let target = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            try privateCopy(source,target)
            let (digest,size) = try hashFile(target)
            try requireStorage(try hashFile(source).0 == digest,"Source changed during backup.","stale_revision")
            let (uid,gid,mode) = try metadata(source)
            entries.append(BackupFile(name:name,digest:digest,size:size,uid:uid,gid:gid,mode:mode))
        }
        #if HOST_STORAGE_TEST
        try duringBackup?()
        #endif
        try requireStorage(try fingerprint() == revision,"Sources changed during backup.","stale_revision")
        let directories = try inventory().directories.map { name,path -> BackupDirectory in
            let (uid,gid,mode) = try metadata(path)
            return BackupDirectory(name:name,uid:uid,gid:gid,mode:mode)
        }
        for directory in directories {
            try FileManager.default.createDirectory(at:folder.appendingPathComponent(directory.name),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        }
        let manifest = BackupManifest(format:2,revision:revision,files:entries,directories:directories)
        try privateWrite(JSONEncoder().encode(manifest),folder.appendingPathComponent("manifest.json"))
        _ = try verifyBackup(id,expected:revision)
        let fd = open(folder.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW); if fd >= 0 { _ = fsync(fd); close(fd) }
        return id
    }
    @discardableResult public func verifyBackup(_ id: String, expected: String? = nil) throws -> String {
        try requireStorage(UUID(uuidString:id) != nil,"Invalid backup identifier.","invalid_input")
        let folder = backups.appendingPathComponent(id)
        try rejectLinks(folder)
        let manifest = try JSONDecoder().decode(BackupManifest.self,from:boundedBytes(folder.appendingPathComponent("manifest.json"),maximum:4*1024*1024))
        try requireStorage(manifest.format == 2 && !manifest.files.isEmpty && manifest.files.count <= 30000,"Unsupported backup.","backup_failed")
        if let expected { try requireStorage(manifest.revision == expected,"Backup revision mismatch.","backup_failed") }
        let names = manifest.files.map(\.name)
        try requireStorage(Set(names).count == names.count && names.contains("knowledgeC.db") && names.contains(where:{$0.hasPrefix("segment-")}),"Incomplete backup.","backup_failed")
        var combined = SHA256()
        for file in manifest.files {
            try requireStorage(safeBackupName(file.name),"Unsafe manifest name.","backup_failed")
            let target = folder.appendingPathComponent(file.name), (digest,size) = try hashFile(target)
            try requireStorage(digest == file.digest && size == file.size,"Backup checksum mismatch.","backup_failed")
            combined.update(data:Data((file.name+"\u{0}"+digest+"|\(file.uid)|\(file.gid)|\(file.mode)\n").utf8))
            if file.name.hasPrefix("segment-") || file.name.hasPrefix("lock-") { _ = try Segment.parse(boundedBytes(target)) }
        }
        try requireStorage(Set(manifest.directories.map(\.name)).count == manifest.directories.count,"Duplicate directory metadata.","backup_failed")
        for directory in manifest.directories {
            try requireStorage(safeBackupName(directory.name) && directory.name.hasPrefix("cache-"),"Unsafe directory metadata.","backup_failed")
            combined.update(data:Data((directory.name+"|\(directory.uid)|\(directory.gid)|\(directory.mode)\n").utf8))
        }
        let digest = combined.finalize().map { String(format:"%02x",$0) }.joined()
        try requireStorage(digest == manifest.revision,"Backup fingerprint mismatch.","backup_failed")
        let db = try KnowledgeDatabase(folder.appendingPathComponent("knowledgeC.db"))
        var valid = false
        try db.query("PRAGMA quick_check") { row in if let text = sqlite3_column_text(row,0) { valid = String(cString:text) == "ok" } }
        try requireStorage(valid,"Backup database failed integrity check.","backup_failed")
        return manifest.revision
    }
    func cacheRevision() throws -> String {
        var hash = SHA256()
        let list = try inventory()
        for (name,path) in list.files where name.hasPrefix("cache-") {
            let (digest,_) = try hashFile(path)
            let (uid,gid,mode) = try metadata(path)
            hash.update(data:Data((name+"|"+digest+"|\(uid)|\(gid)|\(mode)").utf8))
        }
        for (name,path) in list.directories {
            let (uid,gid,mode) = try metadata(path)
            hash.update(data:Data((name+"|\(uid)|\(gid)|\(mode)").utf8))
        }
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    func safeBackupName(_ name: String) -> Bool {
        let parts = name.split(separator:"/",omittingEmptySubsequences:false)
        guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return false }
        return name.hasPrefix("segment-") || name.hasPrefix("lock-") || name.hasPrefix("cache-") || ["knowledgeC.db","knowledgeC.db-wal","knowledgeC.db-shm"].contains(name)
    }
    func writeExisting(_ path: URL, original: Data, replacement: Data) throws {
        let fd = try regularFD(path,flags:O_RDWR); defer { close(fd) }
        var bytes = Data(count:original.count)
        let count = bytes.withUnsafeMutableBytes { pread(fd,$0.baseAddress,$0.count,0) }
        try requireStorage(count == original.count && bytes == original,"Store changed before write.","concurrent_change")
        try replacement.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = pwrite(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset,off_t(offset))
                try requireStorage(n > 0,"Store write failed.","partial_apply_failed"); offset += n
            }
        }
        try requireStorage(ftruncate(fd,off_t(replacement.count)) == 0 && fsync(fd) == 0,"Store sync failed.","partial_apply_failed")
    }
    func prepareLocks(_ request: ApplyRequest) throws -> [(URL,Data,Data)] {
        guard let path = try lockSegments().last else { return [] }
        let old = try boundedBytes(path)
        var segment = try Segment.parse(old)
        // ScreenLocked is a system stream, not an AppUsage protobuf.
        let valid = segment.records.filter { $0.state == 1 && ($0.payload == Data([8,0]) || $0.payload == Data([8,1])) }
        let preceding = valid.filter { $0.timestamp < request.start }.max { $0.timestamp < $1.timestamp }
        let following = valid.filter { $0.timestamp >= request.end }.min { $0.timestamp < $1.timestamp }
        segment.records.removeAll { $0.state == 1 && ($0.payload == Data([8,0]) || $0.payload == Data([8,1])) && $0.timestamp >= request.start && $0.timestamp < request.end }
        var ranges: [(Double,Double)] = []
        for session in request.sessions.sorted(by: { $0.start < $1.start }) {
            if let last = ranges.last, session.start <= last.1 { ranges[ranges.count-1].1 = max(last.1,session.end) }
            else { ranges.append((session.start,session.end)) }
        }
        // Establish locked state in gaps, then restore the state that held at end.
        segment.records.append(SegmentRecord(timestamp:request.start,payload:Data([8,1])))
        for (start,end) in ranges {
            segment.records.append(SegmentRecord(timestamp:start,payload:Data([8,0])))
            segment.records.append(SegmentRecord(timestamp:end,payload:Data([8,1])))
        }
        let endState = valid.filter { $0.timestamp < request.end }.max { $0.timestamp < $1.timestamp } ?? preceding
        if following?.timestamp != request.end, let endState {
            segment.records.append(SegmentRecord(timestamp:request.end,payload:endState.payload))
        }
        segment.records = segment.records.enumerated().sorted { $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp }.map(\.element)
        return [(path,old,try segment.encoded())]
    }
    public func apply(_ request: ApplyRequest) throws -> HelperReply {
        try validClock(request.start); try validClock(request.end)
        try requireStorage(request.start < request.end && request.end-request.start <= 90000 && request.sessions.count <= 10000 && request.revision.count == 64,"Invalid edit interval.","invalid_input")
        for s in request.sessions {
            try requireStorage(SessionRules.isValidBundleID(s.bundle) && s.start.isFinite && s.end.isFinite && s.start >= request.start && s.end <= request.end && s.end-s.start >= 60,"Invalid session.","invalid_input")
        }
        let snapshot = try readSnapshot()
        try requireStorage(request.overrideSourceChanges || request.revision == snapshot.revision,"Screen Time changed since loading. Reload or explicitly override.","stale_revision")
        let paths = try segments(), path = paths.last!
        let original = try boundedBytes(path)
        var segment = try Segment.parse(original)
        let latest = try pairUsage(events([path]))
        var remove = Set<String>(), outside: [StoredSession] = []
        func key(_ bundle:String,_ time:Double) -> String { bundle+"|"+String((time == 0 ? 0.0 : time).bitPattern) }
        for s in latest where s.end > request.start && s.start < request.end {
            remove.insert(key(s.bundle,s.start)); remove.insert(key(s.bundle,s.end))
            if s.start < request.start { outside.append(StoredSession(bundle:s.bundle,start:s.start,end:request.start)) }
            if s.end > request.end { outside.append(StoredSession(bundle:s.bundle,start:request.end,end:s.end)) }
        }
        segment.records = segment.records.filter { record in
            if record.state != 1 { return true }
            if let event = try? AppUsageProto.decode(record.payload) {
                return !remove.contains(key(event.bundle,record.timestamp)) && (record.timestamp < request.start || record.timestamp >= request.end || (record.timestamp == request.start && !event.opening))
            }
            return true // Preserve opaque/undecodable historical records.
        }
        var older: [String:Int] = [:]
        for s in try pairUsage(events(Array(paths.dropLast()))) where s.end > request.start && s.start < request.end {
            let k = key(s.bundle,max(s.start,request.start))+"|"+String((min(s.end,request.end) == 0 ? 0.0 : min(s.end,request.end)).bitPattern)
            older[k,default:0] += 1
        }
        var edited: [StoredSession] = []
        for s in request.sessions {
            let k = key(s.bundle,s.start)+"|"+String((s.end == 0 ? 0.0 : s.end).bitPattern)
            if older[k,default:0] > 0 { older[k]! -= 1 } else { edited.append(s) }
        }
        for s in edited + outside {
            for event in [UsageEvent(opening:true,time:s.start,bundle:s.bundle),UsageEvent(opening:false,time:s.end,bundle:s.bundle)] {
                segment.records.append(SegmentRecord(timestamp:event.time,payload:try AppUsageProto.encode(event)))
            }
        }
        segment.records = segment.records.enumerated().sorted { $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp }.map(\.element)
        let serialized = try segment.encoded()
        var databaseSessions = request.sessions
        do {
            let db = try KnowledgeDatabase(database)
            for s in try db.sessions(start:request.start,end:request.end) {
                if s.start < request.start { databaseSessions.append(StoredSession(bundle:s.bundle,start:s.start,end:request.start)) }
                if s.end > request.end { databaseSessions.append(StoredSession(bundle:s.bundle,start:request.end,end:s.end)) }
            }
        }
        let lockPlans = try prepareLocks(request)
        let cacheBefore = try cacheRevision()
        // Every apply, including stale override, takes a NEW verified CURRENT backup.
        let backupID = try backup()
        #if HOST_STORAGE_TEST
        try afterBackup?()
        #endif
        try verifyBackup(backupID,expected:snapshot.revision)
        try requireStorage(try fingerprint() == snapshot.revision,"Source changed while preparing backup; nothing applied.","stale_revision")
        let db = try KnowledgeDatabase(database,writable:true)
        try db.execute("BEGIN IMMEDIATE")
        var segmentWritten = false
        do {
            #if HOST_STORAGE_TEST
            try beforeTransactionWrite?()
            #endif
            try requireStorage(try fingerprint() == snapshot.revision,"Source changed before write.","stale_revision")
            try db.replace(start:request.start,end:request.end,sessions:databaseSessions)
            let fd = try regularFD(path,flags:O_RDWR); defer { close(fd) }
            var info = stat(); try requireStorage(fstat(fd,&info) == 0 && info.st_size == original.count,"Segment replaced.","concurrent_change")
            // Re-read same descriptor; never truncate a replaced path.
            var current = Data(count:original.count)
            let readCount = current.withUnsafeMutableBytes { pread(fd,$0.baseAddress,$0.count,0) }
            try requireStorage(readCount == original.count && current == original,"Segment changed before write.","concurrent_change")
            try serialized.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = pwrite(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset,off_t(offset))
                    try requireStorage(n > 0,"Segment write failed.","partial_apply_failed")
                    segmentWritten = true; offset += n
                }
            }
            try requireStorage(ftruncate(fd,off_t(serialized.count)) == 0 && fsync(fd) == 0,"Segment sync failed.","partial_apply_failed")
            for (lockPath,old,new) in lockPlans {
                segmentWritten = true
                try writeExisting(lockPath,original:old,replacement:new)
            }
            try db.replaceLocks(start:request.start,end:request.end,sessions:request.sessions,enabled:lockStream != nil)
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            if !segmentWritten, let failure = error as? StorageFailure, failure.code == "stale_revision" { throw failure }
            throw StorageFailure(segmentWritten ? "partial_apply_failed" : "apply_failed","\(error). Verified current backup \(backupID). Stores are not one atomic transaction.")
        }
        do {
            // Root discovery and complete inventory already included in the verified backup.
            try requireStorage(try cacheRevision() == cacheBefore,"DeviceActivity cache changed after backup; cache not cleared.","concurrent_change")
            for root in try cacheRoots() {
                for child in try FileManager.default.contentsOfDirectory(at:root,includingPropertiesForKeys:nil) {
                    try rejectLinks(child)
                    try FileManager.default.removeItem(at:child)
                }
            }
            try refreshRunner(["Preferences","ScreenTimeSettingsAgent"])
        } catch {
            throw StorageFailure("refresh_failed","Usage saved but refresh failed. Verified backup \(backupID). \(error)")
        }
        return HelperReply(ok:true,code:"refresh_requested",message:"Saved and requested Screen Time refresh. Device UI verification remains required.",details:["backupID":backupID,"revision":snapshot.revision,"writer":"original_local_native","multiStoreAtomic":"false"])
    }
}
