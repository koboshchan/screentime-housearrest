import Foundation
import Darwin

/// Full native inject_ios.main writer with selected sessions and verified backup.
/// Request data selects sessions and a day only. All paths belong to NativeStorage.
enum GeminiIOSRoute {
    static func rewrite(_ original: Data, request: ApplyRequest, locks: Bool) throws -> Data {
        var segment = try Segment.parse(original)
        // Original Gemini filter deliberately operates on ALL record timestamps.
        segment.records.removeAll { $0.timestamp >= request.start && $0.timestamp < request.end }
        for session in request.sessions {
            if locks {
                segment.records.append(SegmentRecord(timestamp:session.start,payload:Data([8,0])))
                segment.records.append(SegmentRecord(timestamp:session.end,payload:Data([8,1])))
            } else {
                for event in [UsageEvent(opening:true,time:session.start,bundle:session.bundle),
                              UsageEvent(opening:false,time:session.end,bundle:session.bundle)] {
                    segment.records.append(SegmentRecord(timestamp:event.time,payload:try AppUsageProto.encode(event)))
                }
            }
        }
        // Python sort is stable. Preserve input order at equal timestamps.
        segment.records = segment.records.enumerated().sorted {
            $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
        return try segment.encoded()
    }

    /// Same fixed sync-then-open fallback as Gemini. No shell, SSH, Python or
    /// caller-selected executable/arguments. Missing jailbreak utilities fail explicitly.
    static func refresh() throws {
        func run(_ path: String, _ arguments: [String]) -> Bool {
            var pid: pid_t = 0
            let strings = ([path]+arguments).map { strdup($0) }
            defer { for string in strings { free(string) } }
            var argv = strings + [nil]
            let rc = argv.withUnsafeMutableBufferPointer {
                posix_spawn(&pid,path,nil,nil,$0.baseAddress!,environ)
            }
            guard rc == 0 else { return false }
            var status: Int32 = 0
            while waitpid(pid,&status,0) < 0 {
                if errno != EINTR { return false }
            }
            return status == 0
        }
        if run("/usr/bin/screentime-cli",["sync"]) { return }
        try requireStorage(run("/usr/bin/uiopen",["--url","prefs:root=SCREEN_TIME"]),
                           "Usage saved, but neither fixed Screen Time refresh utility succeeded. Open Settings manually; runtime verification is required.","refresh_failed")
    }
}

extension NativeStorage {
    public func apply(_ request: ApplyRequest) throws -> HelperReply {
        try validClock(request.start); try validClock(request.end)
        try requireStorage(request.start < request.end && request.end-request.start <= 90000 && request.sessions.count <= 10000 && request.revision.count == 64,"Invalid edit interval.","invalid_input")
        for session in request.sessions {
            try requireStorage(SessionRules.isValidBundleID(session.bundle) && session.start.isFinite && session.end.isFinite && session.start >= request.start && session.end <= request.end && session.end-session.start >= 60,"Invalid session.","invalid_input")
        }
        let before = try fingerprint()
        try requireStorage(request.overrideSourceChanges || before == request.revision,"Screen Time changed since loading. Reload or explicitly override.","stale_revision")
        // Original proof pinned segment IDs. Select the newest local segment instead,
        // deterministically, without accepting device IDs or paths from the caller.
        let usagePath = try segments().last!
        guard let lockPath = try lockSegments().last else {
            throw StorageFailure("unsupported_schema","Device.ScreenLocked storage was not found; nothing applied.")
        }
        let usageOld = try boundedBytes(usagePath), lockOld = try boundedBytes(lockPath)
        let usageNew = try GeminiIOSRoute.rewrite(usageOld,request:request,locks:false)
        let lockNew = try GeminiIOSRoute.rewrite(lockOld,request:request,locks:true)
        do { let db = try KnowledgeDatabase(database); try db.validateGeminiSchema() }
        let cacheBefore = try cacheRevision()
        let id = try backup()
        #if HOST_STORAGE_TEST
        try afterBackup?()
        #endif
        try verifyBackup(id,expected:before)
        try requireStorage(try fingerprint() == before,"Source changed during backup; nothing applied.","stale_revision")
        do {
            // Original standalone pre-write UI stop, only after verified backup.
            try refreshRunner(["Preferences","ScreenTimeSettingsAgent"])
            try writeExisting(usagePath,original:usageOld,replacement:usageNew)
            try writeExisting(lockPath,original:lockOld,replacement:lockNew)
            let db = try KnowledgeDatabase(database,writable:true)
            try db.execute("BEGIN IMMEDIATE")
            do { try db.replaceGemini(request); try db.execute("COMMIT") }
            catch { try? db.execute("ROLLBACK"); throw error }
            try requireStorage(try cacheRevision() == cacheBefore,"DeviceActivity cache changed after backup; cache not cleared.","concurrent_change")
            for root in try cacheRoots() {
                // Gemini rm -rf Local removes the root too; do not merely empty it.
                try rejectLinks(root)
                try FileManager.default.removeItem(at:root)
            }
            try refreshRunner(["gemini-sync-or-open"])
        } catch {
            throw StorageFailure("partial_apply_failed","\(error). Verified current backup \(id). Stores are not one atomic transaction.")
        }
        return HelperReply(ok:true,code:"refresh_requested",message:"Saved using the original Gemini iOS route. Device runtime verification remains required.",details:["backupID":id,"revision":before,"writer":"gemini_ios_full_native","knowledgeC":"full_gemini_rewrite","multiStoreAtomic":"false"])
    }
}
