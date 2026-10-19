import Foundation
import SQLite3
@main struct GeminiRouteChecks {
 static var count = 0
 static func check(_ value: Bool) { precondition(value); count += 1 }
 static func main() throws {
  let sessions = [StoredSession(bundle:"com.apple.mobilesafari",start:120,end:180)]
  let req = ApplyRequest(start:100,end:200,sessions:sessions,revision:String(repeating:"0",count:64))
  let rows = [SegmentRecord(timestamp:99,payload:Data([8,1])),
              SegmentRecord(timestamp:100,payload:Data([255])),
              SegmentRecord(timestamp:150,payload:Data([8,0])),
              SegmentRecord(timestamp:200,payload:Data([8,1]))]
  let original = try Segment(created:10,size:4096,records:rows).encoded()
  let locks = try Segment.parse(GeminiIOSRoute.rewrite(original,request:req,locks:true))
  check(locks.records.map(\.timestamp) == [99,120,180,200])
  check(locks.records.map(\.payload) == [Data([8,1]),Data([8,0]),Data([8,1]),Data([8,1])])
  let usage = try Segment.parse(GeminiIOSRoute.rewrite(original,request:req,locks:false))
  check(usage.size == 4096 && usage.created == 10)
  check(try AppUsageProto.decode(usage.records[1].payload).bundle == "com.apple.mobilesafari")
  check(try AppUsageProto.decode(usage.records[1].payload).opening)
  check(try !AppUsageProto.decode(usage.records[2].payload).opening)
  check(usage.records[1].timestamp == 120 && usage.records[2].timestamp == 180)
  let empty = ApplyRequest(start:100,end:200,sessions:[],revision:req.revision)
  check(try Segment.parse(GeminiIOSRoute.rewrite(original,request:empty,locks:true)).records.count == 2)
  let twice = ApplyRequest(start:100,end:200,sessions:sessions+sessions,revision:req.revision)
  check(try Segment.parse(GeminiIOSRoute.rewrite(original,request:twice,locks:false)).records.count == 6)
  let folder = URL(fileURLWithPath:"/private/tmp").appendingPathComponent("ste-reader-"+UUID().uuidString)
  try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
  defer { try? FileManager.default.removeItem(at:folder) }
  let first = folder.appendingPathComponent("1"), second = folder.appendingPathComponent("2")
  let events = [UsageEvent(opening:true,time:1,bundle:"com.apple.mobilesafari"),UsageEvent(opening:true,time:2,bundle:"com.apple.mobilesafari"),UsageEvent(opening:false,time:4,bundle:"com.apple.mobilesafari")]
  let records = events.map { SegmentRecord(timestamp:$0.time+100,payload:SEGBV2.encodeAppUsage(cocoaTs:999,starting:$0.opening,bundleId:$0.bundle)) }
  try privateWrite(Segment(created:0,size:4096,records:records).encoded(),first)
  check(try GeminiSwiftReader.sessions([first]) == [StoredSession(bundle:"com.apple.mobilesafari",start:102,end:104)])
  try privateWrite(Segment(created:0,size:4096,records:[records[0]]).encoded(),first.appendingPathExtension("open"))
  try privateWrite(Segment(created:0,size:4096,records:[records[2]]).encoded(),second)
  check(try GeminiSwiftReader.sessions([first.appendingPathExtension("open"),second]).isEmpty)
  // No process API calls or real sleeps in these synthetic exit-barrier tests.
  var probes = 0, pauses = 0
  try RefreshExitBarrier.wait([],stillRunning: { _,_ in probes += 1; return true },
                             pause: { pauses += 1 })
  check(probes == 0 && pauses == 0)
  try RefreshExitBarrier.wait([(20,"ScreenTimeAgent")],
      stillRunning: { pid,name in
          check(pid == 20 && name == "ScreenTimeAgent")
          probes += 1
          return probes < 3
      },pause: { pauses += 1 },attempts:3)
  check(probes == 3 && pauses == 2)
  probes = 0; pauses = 0
  do {
      try RefreshExitBarrier.wait([(21,"UsageTrackingAgent")],
          stillRunning: { _,_ in probes += 1; return true },
          pause: { pauses += 1 },attempts:3)
      preconditionFailure("stuck agent must not report refresh success")
  } catch { check((error as? StorageFailure)?.code == "refresh_failed") }
  check(probes == 3 && pauses == 2)
  pauses = 0
  do {
      try RefreshExitBarrier.wait([(22,"ScreenTimeAgent")],
          stillRunning: { _,_ in throw StorageFailure("probe_error","synthetic") },
          pause: { pauses += 1 },attempts:3)
      preconditionFailure("probe failure must propagate")
  } catch { check((error as? StorageFailure)?.code == "probe_error") }
  check(pauses == 0)
  probes = 0; pauses = 0
  try RefreshExitBarrier.wait([(30,"Preferences"),(31,"ScreenTimeAgent")],
      stillRunning: { pid,_ in probes += 1; return pid == 31 && probes < 4 },
      pause: { pauses += 1 },attempts:3)
  check(probes == 4 && pauses == 2) // exited UI PID never gets re-probed
  do {
      try RefreshExitBarrier.wait([],stillRunning: { _,_ in false },pause: {},attempts:0)
      preconditionFailure("invalid bound must fail")
  } catch { check((error as? StorageFailure)?.code == "refresh_failed") }
  print("PASS Gemini iOS route \(count) exact filter/payload/order checks; synthetic bytes only")
 }
}
