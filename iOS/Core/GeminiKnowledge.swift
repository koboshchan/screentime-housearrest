import Foundation
import SQLite3

extension KnowledgeDatabase {
 static let geminiColumns = ["ZUUIDHASH","ZCOMPATIBILITYVERSION","ZENDDAYOFWEEK","ZENDSECONDOFDAY","ZHASCUSTOMMETADATA","ZHASSTRUCTUREDMETADATA","ZSECONDSFROMGMT","ZSHOULDSYNC","ZSTARTDAYOFWEEK","ZSTARTSECONDOFDAY","ZVALUECLASS","ZVALUEINTEGER","ZVALUETYPECODE","ZSTRUCTUREDMETADATA","ZLOCALCREATIONDATE","ZCONFIDENCE","ZVALUEDOUBLE","ZUUID"]
 func validateGeminiSchema() throws {
  var columns = Set<String>()
  try query("PRAGMA table_info(ZOBJECT)") { row in
   if let text = sqlite3_column_text(row,1) { columns.insert(String(cString:text)) }
  }
  try requireStorage(Set(Self.geminiColumns).isSubset(of:columns),"Full Gemini knowledgeC schema is unavailable; nothing applied.","unsupported_schema")
 }
 /// Full standalone inject_ios.main SQL, with per-session IDs and calendar metadata.
 /// Its broad overlap DELETE is intentional original behavior, including other streams.
 func replaceGemini(_ request: ApplyRequest) throws {
  try validateGeminiSchema()
  try query("DELETE FROM ZOBJECT WHERE ZENDDATE > ? AND ZSTARTDATE < ?",parameters:[request.start,request.end]) { _ in }
  for session in request.sessions {
   for locked in [false,true] {
    let start = Date(timeIntervalSinceReferenceDate:session.start)
    let end = Date(timeIntervalSinceReferenceDate:session.end)
    let calendar = Calendar.current
    let weekdayStart = (calendar.component(.weekday,from:start)+5)%7 // Python weekday, Monday=0
    let weekdayEnd = (calendar.component(.weekday,from:end)+5)%7
    let startSeconds = Int(session.start-calendar.startOfDay(for:start).timeIntervalSinceReferenceDate)
    let endSeconds = Int(session.end-calendar.startOfDay(for:end).timeIntervalSinceReferenceDate)
    let identifier = UUID()
    // Positive signed 63-bit hash replaces the proof's fixed sample hash.
    var bytes = identifier.uuid
    let hash = withUnsafeBytes(of:&bytes) { $0.loadUnaligned(as:UInt64.self) & 0x7fffffffffffffff }
    let sql = """
    INSERT INTO ZOBJECT (
      Z_ENT,Z_OPT,ZUUIDHASH,ZCOMPATIBILITYVERSION,ZENDDAYOFWEEK,ZENDSECONDOFDAY,
      ZHASCUSTOMMETADATA,ZHASSTRUCTUREDMETADATA,ZSECONDSFROMGMT,ZSHOULDSYNC,
      ZSTARTDAYOFWEEK,ZSTARTSECONDOFDAY,ZVALUECLASS,ZVALUEINTEGER,ZVALUETYPECODE,
      ZSTRUCTUREDMETADATA,ZCREATIONDATE,ZLOCALCREATIONDATE,ZCONFIDENCE,
      ZENDDATE,ZSTARTDATE,ZVALUEDOUBLE,ZUUID,ZSTREAMNAME,ZVALUESTRING
    ) VALUES (?,1,?,0,?,?,0,?,?,0,?,?,?,?,?,NULL,?,?,1.0,?,?,?,?,?,?)
    """
    var statement: OpaquePointer?
    try requireStorage(sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK,"Cannot prepare full Gemini insertion.","unsupported_schema")
    defer { sqlite3_finalize(statement) }
    let integers: [(Int32,Int64)] = [
     (1,Int64(usageEntity)),(2,Int64(hash)),(3,Int64(weekdayEnd)),(4,Int64(endSeconds)),
     (5,locked ? 0:1),(6,Int64(TimeZone.current.secondsFromGMT(for:start))),
     (7,Int64(weekdayStart)),(8,Int64(startSeconds)),(9,locked ? 2:1),
     (10,locked ? 0:3435207421084723711),(11,locked ? -2475731913145812025:6584185901589580638)]
    for (index,value) in integers { sqlite3_bind_int64(statement,index,value) }
    for index: Int32 in [12,13,14] { sqlite3_bind_double(statement,index,session.end) }
    sqlite3_bind_double(statement,15,session.start)
    sqlite3_bind_double(statement,16,locked ? 0:3.4352074210847237e18)
    let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    sqlite3_bind_text(statement,17,identifier.uuidString,-1,transient)
    sqlite3_bind_text(statement,18,locked ? "/device/isLocked":"/app/usage",-1,transient)
    if locked { sqlite3_bind_null(statement,19) }
    else { sqlite3_bind_text(statement,19,session.bundle,-1,transient) }
    try requireStorage(sqlite3_step(statement) == SQLITE_DONE,"Full Gemini knowledgeC insertion failed.","database_failed")
   }
  }
 }
}
