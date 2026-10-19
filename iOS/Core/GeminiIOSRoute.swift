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

    /// The unhooked privileged helper sees the stock root filesystem, not the
    /// jailbreak shell's remapped /usr/bin. Refresh by exact kernel process names;
    /// no executable lookup, shell, environment injection or cache deletion.
    static let refreshTargets = ["Preferences", "ScreenTimeSettingsAgent",
                                 "ScreenTimeAgent", "UsageTrackingAgent", "biomed"]
    static func refresh() throws {
        try NativeStorage.refreshProcesses(refreshTargets)
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
        // Plan every changed stream before backup or mutation. Preserve the Gemini
        // writer and add native aggregate-input normalization around it.
        let usagePlans = try prepareNativeUsage(request)
        guard let lockPath = try lockSegments().last else {
            throw StorageFailure("unsupported_schema","Device.ScreenLocked storage was not found; nothing applied.")
        }
        let lockOld = try boundedBytes(lockPath)
        let lockNew = try GeminiIOSRoute.rewrite(lockOld,request:request,locks:true)
        let backlightPlans = try prepareBacklight(request)
        let appTotalPlans = try prepareAppTotals(request)
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
            for (path,old,new) in usagePlans + backlightPlans {
                try writeExisting(path,original:old,replacement:new)
            }
            try writeExisting(lockPath,original:lockOld,replacement:lockNew)
            let db = try KnowledgeDatabase(database,writable:true)
            try db.execute("BEGIN IMMEDIATE")
            do { try db.replaceGemini(request); try db.execute("COMMIT") }
            catch { try? db.execute("ROLLBACK"); throw error }
            try requireStorage(try cacheRevision() == cacheBefore,"DeviceActivity cache changed after backup; cache totals not written.","concurrent_change")
            // Preserve the Gemini stream/database writer. Replace cache deletion
            // with native apps-only segments and the proven future-metadata bypass.
            // Metadata plans are last so no partial segment plan is marked fresh.
            for plan in appTotalPlans { try writeAppTotal(plan) }
            try refreshRunner(["gemini-sync-or-open"])
        } catch {
            throw StorageFailure("partial_apply_failed","\(error). Verified current backup \(id). Stores are not one atomic transaction.")
        }
        return HelperReply(ok:true,code:"refresh_requested",message:"Saved summed app totals and requested refresh. Native category aggregates are preserved and may be stale. Native cache refresh is held for at least 30 days; later usage will not refresh automatically during that hold. Open Settings to verify.",details:["backupID":id,"revision":before,"writer":"gemini_ios_full_native","knowledgeC":"full_gemini_rewrite","aggregateInputs":"usage_and_backlight","totalPolicy":"sum_apps_including_overlap","categoryPolicy":"preserve_native_may_be_stale","cacheRefresh":"held_at_least_30_days","multiStoreAtomic":"false"])
    }
}
