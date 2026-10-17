import Foundation
import SQLite3
@main struct GeminiAllocationChecks {
 static var count = 0
 static func check(_ value: Bool) { precondition(value); count += 1 }
 static func scalar(_ db: KnowledgeDatabase, _ sql: String) throws -> Int64 {
  var value: Int64 = -1
  try db.query(sql) { value = sqlite3_column_int64($0,0) }
  return value
 }
 static func main() throws {
  let folder = URL(fileURLWithPath:"/private/tmp/ste-keys-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
  defer { try? FileManager.default.removeItem(at:folder) }
  for (index,reserved) in [Int64(100),Int64(5)].enumerated() {
   let path = folder.appendingPathComponent("\(index).db")
   var raw: OpaquePointer?
   check(sqlite3_open(path.path,&raw) == SQLITE_OK)
   let extras = KnowledgeDatabase.geminiColumns.map { "\($0) \($0 == "ZUUID" ? "TEXT":"NUMERIC")" }.joined(separator:",")
   let sql = """
   CREATE TABLE Z_PRIMARYKEY (Z_ENT INTEGER PRIMARY KEY,Z_NAME TEXT,Z_SUPER INTEGER,Z_MAX INTEGER);
   INSERT INTO Z_PRIMARYKEY VALUES(1,'Object',0,\(reserved)),(11,'Event',1,999);
   CREATE TABLE ZOBJECT (Z_PK INTEGER PRIMARY KEY,Z_ENT INTEGER,Z_OPT INTEGER,ZSTREAMNAME TEXT,ZSTARTDATE REAL,ZENDDATE REAL,ZVALUESTRING TEXT,ZCREATIONDATE REAL,\(extras));
   INSERT INTO ZOBJECT (Z_PK,Z_ENT,ZSTREAMNAME,ZSTARTDATE,ZENDDATE) VALUES(40,11,'/app/usage',120,180);
   """
   check(sqlite3_exec(raw,sql,nil,nil,nil) == SQLITE_OK)
   sqlite3_close(raw)
   let db = try KnowledgeDatabase(path,writable:true)
   let req = ApplyRequest(start:100,end:200,sessions:[StoredSession(bundle:"com.apple.mobilesafari",start:120,end:180)],revision:String(repeating:"0",count:64))
   var rejected = false
   do { try db.replaceGemini(req) } catch { rejected = true }
   check(rejected)
   try db.execute("BEGIN IMMEDIATE")
   try db.replaceGemini(req)
   let base = max(reserved,40)
   check(try scalar(db,"SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_ENT=1") == base+2)
   check(try scalar(db,"SELECT Z_PK FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage'") == base+1)
   check(try scalar(db,"SELECT COUNT(*) FROM ZOBJECT WHERE ZSTREAMNAME='/device/isLocked' AND ZVALUESTRING IS NULL") == 1)
   try db.execute("ROLLBACK")
   check(try scalar(db,"SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_ENT=1") == reserved)
   check(try scalar(db,"SELECT MAX(Z_PK) FROM ZOBJECT") == 40)
   try db.execute("BEGIN IMMEDIATE"); try db.replaceGemini(req); try db.execute("COMMIT")
   try db.execute("BEGIN IMMEDIATE")
   try db.execute("UPDATE Z_PRIMARYKEY SET Z_MAX=Z_MAX+1 WHERE Z_ENT=1")
   try db.execute("INSERT INTO ZOBJECT (Z_PK,Z_ENT,ZSTREAMNAME) SELECT Z_MAX,11,'natural' FROM Z_PRIMARYKEY WHERE Z_ENT=1")
   try db.execute("COMMIT")
   check(try scalar(db,"SELECT COUNT(*) FROM ZOBJECT WHERE ZVALUESTRING='com.apple.mobilesafari'") == 1)
   check(try scalar(db,"SELECT MAX(Z_PK) FROM ZOBJECT") == base+3)
   let empty = ApplyRequest(start:100,end:200,sessions:[],revision:req.revision)
   try db.execute("BEGIN IMMEDIATE"); try db.replaceGemini(empty); try db.execute("COMMIT")
   check(try scalar(db,"SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_ENT=1") == base+3)
   check(try scalar(db,"SELECT COUNT(*) FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage'") == 0)
   // Device schema has Object itself as the usage entity (Z_ENT=9).
   try db.execute("UPDATE ZOBJECT SET Z_ENT=9; DELETE FROM Z_PRIMARYKEY; INSERT INTO Z_PRIMARYKEY VALUES(9,'Object',0,500)")
   db.usageEntity = 9
   try db.execute("BEGIN IMMEDIATE"); try db.replaceGemini(req); try db.execute("COMMIT")
   check(try scalar(db,"SELECT Z_MAX FROM Z_PRIMARYKEY WHERE Z_ENT=9") == 502)
   check(try scalar(db,"SELECT Z_PK FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage'") == 501)
   check(try scalar(db,"SELECT Z_ENT FROM ZOBJECT WHERE ZSTREAMNAME='/app/usage'") == 9)
   // Malformed root must fail before the broad deletion, even for zero sessions.
   try db.execute("UPDATE Z_PRIMARYKEY SET Z_SUPER=9 WHERE Z_ENT=9")
   try db.execute("BEGIN IMMEDIATE")
   rejected = false
   do { try db.replaceGemini(empty) } catch { rejected = true }
   check(rejected); try db.execute("ROLLBACK")
   check(try scalar(db,"SELECT COUNT(*) FROM ZOBJECT WHERE ZSTREAMNAME='natural'") == 1)
  }
  print("PASS Gemini Core Data allocation \(count) checks; synthetic SQLite only")
 }
}
