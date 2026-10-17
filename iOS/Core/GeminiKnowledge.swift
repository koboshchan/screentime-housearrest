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
 /// Core Data reserves IDs on the inheritance root, not the concrete entity.
 /// Caller owns BEGIN IMMEDIATE; reservation and inserts commit/roll back together.
 func reserveGeminiKeys(_ count: Int64) throws -> Int64 {
  try requireStorage(sqlite3_get_autocommit(db) == 0,"Primary keys require the caller transaction.","database_failed")
  var pkValid = false
  try query("PRAGMA table_info(ZOBJECT)") { row in
   if let name = sqlite3_column_text(row,1), String(cString:name) == "Z_PK",
      let type = sqlite3_column_text(row,2) {
    pkValid = String(cString:type).uppercased() == "INTEGER" && sqlite3_column_int(row,5) == 1
   }
  }
  try requireStorage(pkValid,"Unsupported Core Data primary key schema.","unsupported_schema")
  var metadata: [Int64:(String,Int64,Int64)] = [:]
  try query("SELECT Z_ENT,Z_NAME,Z_SUPER,Z_MAX FROM Z_PRIMARYKEY") { row in
   try requireStorage([0,2,3].allSatisfy { sqlite3_column_type(row,Int32($0)) == SQLITE_INTEGER },
                      "Invalid Core Data key metadata.","unsupported_schema")
   let entity = sqlite3_column_int64(row,0)
   guard let text = sqlite3_column_text(row,1) else { throw StorageFailure("unsupported_schema","Missing entity name.") }
   let name = String(cString:text), parent = sqlite3_column_int64(row,2), maximum = sqlite3_column_int64(row,3)
   try requireStorage(entity > 0 && parent >= 0 && maximum >= 0 && metadata[entity] == nil,
                      "Ambiguous Core Data key metadata.","unsupported_schema")
   metadata[entity] = (name,parent,maximum)
  }
  var root = Int64(usageEntity), visited = Set<Int64>()
  while true {
   try requireStorage(visited.insert(root).inserted,"Cyclic Core Data inheritance.","unsupported_schema")
   guard let entry = metadata[root] else { throw StorageFailure("unsupported_schema","Missing Core Data inheritance root.") }
   if entry.1 == 0 { break }
   root = entry.1
  }
  guard let entry = metadata[root], entry.0 == "Object" else {
   throw StorageFailure("unsupported_schema","Unsupported Core Data Object root.")
  }
  var maximum: Int64 = 0
  try query("SELECT MAX(Z_PK) FROM ZOBJECT") { row in
   if sqlite3_column_type(row,0) != SQLITE_NULL {
    try requireStorage(sqlite3_column_type(row,0) == SQLITE_INTEGER,"Invalid stored primary key.","unsupported_schema")
    maximum = sqlite3_column_int64(row,0)
   }
  }
  let base = max(maximum,entry.2)
  try requireStorage(base >= 0 && count >= 0 && base <= Int64.max - count,
                     "Core Data key allocation overflow.","unsupported_schema")
  let last = base + count
  try execute("UPDATE Z_PRIMARYKEY SET Z_MAX=\(last) WHERE Z_ENT=\(root)")
  try requireStorage(sqlite3_changes(db) == 1,"Core Data key reservation failed.","database_failed")
  return base
 }
 /// Full standalone inject_ios.main SQL, with per-session IDs and calendar metadata.
 /// Its broad overlap DELETE is intentional original behavior, including other streams.
 func replaceGemini(_ request: ApplyRequest) throws {
  try validateGeminiSchema()
  try requireStorage(request.sessions.count <= Int(Int64.max / 2),"Too many sessions.","size_limit")
  var nextKey = try reserveGeminiKeys(Int64(request.sessions.count) * 2)
  try query("DELETE FROM ZOBJECT WHERE ZENDDATE > ? AND ZSTARTDATE < ?",parameters:[request.start,request.end]) { _ in }
  for session in request.sessions {
   for locked in [false,true] {
    nextKey += 1
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
      Z_PK,Z_ENT,Z_OPT,ZUUIDHASH,ZCOMPATIBILITYVERSION,ZENDDAYOFWEEK,ZENDSECONDOFDAY,
      ZHASCUSTOMMETADATA,ZHASSTRUCTUREDMETADATA,ZSECONDSFROMGMT,ZSHOULDSYNC,
      ZSTARTDAYOFWEEK,ZSTARTSECONDOFDAY,ZVALUECLASS,ZVALUEINTEGER,ZVALUETYPECODE,
      ZSTRUCTUREDMETADATA,ZCREATIONDATE,ZLOCALCREATIONDATE,ZCONFIDENCE,
      ZENDDATE,ZSTARTDATE,ZVALUEDOUBLE,ZUUID,ZSTREAMNAME,ZVALUESTRING
    ) VALUES (?,?,1,?,0,?,?,0,?,?,0,?,?,?,?,?,NULL,?,?,1.0,?,?,?,?,?,?)
    """
    var statement: OpaquePointer?
    try requireStorage(sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK,"Cannot prepare full Gemini insertion.","unsupported_schema")
    defer { sqlite3_finalize(statement) }
    let integers: [(Int32,Int64)] = [
     (1,Int64(usageEntity)),(2,Int64(hash)),(3,Int64(weekdayEnd)),(4,Int64(endSeconds)),
     (5,locked ? 0:1),(6,Int64(TimeZone.current.secondsFromGMT(for:start))),
     (7,Int64(weekdayStart)),(8,Int64(startSeconds)),(9,locked ? 2:1),
     (10,locked ? 0:3435207421084723711),(11,locked ? -2475731913145812025:6584185901589580638)]
    sqlite3_bind_int64(statement,1,nextKey)
    for (index,value) in integers { sqlite3_bind_int64(statement,index+1,value) }
    for index: Int32 in [12,13,14] { sqlite3_bind_double(statement,index+1,session.end) }
    sqlite3_bind_double(statement,16,session.start)
    sqlite3_bind_double(statement,17,locked ? 0:3.4352074210847237e18)
    let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
    sqlite3_bind_text(statement,18,identifier.uuidString,-1,transient)
    sqlite3_bind_text(statement,19,locked ? "/device/isLocked":"/app/usage",-1,transient)
    if locked { sqlite3_bind_null(statement,20) }
    else { sqlite3_bind_text(statement,20,session.bundle,-1,transient) }
    try requireStorage(sqlite3_step(statement) == SQLITE_DONE,"Full Gemini knowledgeC insertion failed.","database_failed")
   }
  }
 }
}
