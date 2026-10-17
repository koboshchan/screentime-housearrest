import Foundation

/// Native Screen Time also folds dangling AppUsage starts and Backlight state.
/// Keep Gemini's reader/writer, correcting those aggregate inputs before refresh.
enum NativeAggregates {
    static func ordered(_ records: [SegmentRecord]) -> [SegmentRecord] {
        records.enumerated().sorted {
            $0.element.timestamp == $1.element.timestamp ? $0.offset < $1.offset : $0.element.timestamp < $1.element.timestamp
        }.map(\.element)
    }
    static func union(_ sessions: [StoredSession]) -> [(Double,Double)] {
        var ranges: [(Double,Double)] = []
        for s in sessions.sorted(by: { $0.start < $1.start }) {
            if let last = ranges.last, s.start <= last.1 { ranges[ranges.count-1].1 = max(last.1,s.end) }
            else { ranges.append((s.start,s.end)) }
        }
        return ranges
    }
    static func backlightPayload(_ time: Double, _ on: Bool) throws -> Data {
        try validClock(time)
        var data = Data([9]), clock = Data(count:8)
        clock.put64(time.bitPattern,0)
        data.append(clock); data.append(contentsOf:[16,on ? 1 : 0])
        return data
    }
    static func backlightState(_ record: SegmentRecord) throws -> Bool {
        // Verified native schema. Unknown fields or wire types fail closed rather
        // than silently discarding an event that might affect outside-day state.
        let data = record.payload
        try requireStorage(record.state == 1 && data.count == 11 && data[0] == 9 && data[9] == 16 && data[10] <= 1,
                           "Unsupported Backlight payload; nothing applied.","unsupported_schema")
        let clock = Double(bitPattern:data.le64(1))
        try validClock(clock)
        try requireStorage(abs(clock-record.timestamp) < 0.001,"Backlight clocks disagree; nothing applied.","unsupported_schema")
        return data[10] == 1
    }
    static func backlight(_ original: Data, history: [SegmentRecord], request: ApplyRequest,
                          now: Double = Date().timeIntervalSinceReferenceDate,
                          preserved: [StoredSession] = []) throws -> Data {
        var segment = try Segment.parse(original)
        let active = ordered(history.filter { $0.state == 1 })
        for row in active { _ = try backlightState(row) }
        // Preserve all opaque states. Reject them in the edit interval since
        // their native meaning is unknown.
        try requireStorage(!history.contains { $0.state != 1 && $0.timestamp >= request.start && $0.timestamp < request.end },
                           "Opaque Backlight event intersects edit; nothing applied.","unsupported_schema")
        let boundary = active.last { $0.timestamp <= request.end }
        if request.end <= now {
            try requireStorage(boundary != nil,"Unknown original Backlight boundary; nothing applied.","unsupported_schema")
        }
        segment.records.removeAll { $0.timestamp >= request.start && $0.timestamp < request.end }
        segment.records.append(SegmentRecord(timestamp:request.start,payload:try backlightPayload(request.start,false)))
        for (a,b) in union(request.sessions) {
            segment.records.append(SegmentRecord(timestamp:a,payload:try backlightPayload(a,true)))
            segment.records.append(SegmentRecord(timestamp:b,payload:try backlightPayload(b,false)))
        }
        // Restore only a real, already elapsed outside boundary. A synthetic
        // future-midnight "on" would invent future screen use.
        if request.end <= now, let boundary {
            segment.records.append(SegmentRecord(timestamp:request.end,payload:try backlightPayload(request.end,backlightState(boundary))))
        }
        // Overlay only proven preserved usage, leaving all other outside state
        // and opaque records byte-for-byte intact. Restore the original state
        // at each closing boundary, not a guessed off state.
        for (a,b) in union(preserved) {
            try requireStorage(a < b && (b <= request.start || a >= request.end),
                               "Preserved coverage intersects edit; nothing applied.","unsupported_schema")
            try requireStorage(!history.contains { $0.state != 1 && $0.timestamp >= a && $0.timestamp <= b },
                               "Opaque Backlight event intersects preserved usage; nothing applied.","unsupported_schema")
            guard let boundary = active.last(where: { $0.timestamp <= b }) else {
                throw StorageFailure("unsupported_schema","Unknown preserved Backlight boundary; nothing applied.")
            }
            segment.records.removeAll { $0.state == 1 && $0.timestamp >= a && $0.timestamp < b }
            segment.records.append(SegmentRecord(timestamp:a,payload:try backlightPayload(a,true)))
            // At the edit start the synthetic baseline owns the boundary.
            // Restoring a preceding natural on-state there would erase a gap.
            if b != request.start {
                segment.records.append(SegmentRecord(timestamp:b,payload:try backlightPayload(b,backlightState(boundary))))
            }
        }
        segment.records = ordered(segment.records)
        return try segment.encoded()
    }
    /// Only unambiguous closed pairs establish natural display coverage.
    /// An orphan stop is retained by the usage writer, never reconstructed here.
    static func preservedUsage(_ records: [SegmentRecord], request: ApplyRequest,
                               calendar: Calendar = .current) throws -> [StoredSession] {
        let date = Date(timeIntervalSinceReferenceDate:request.start)
        let dayStart = calendar.startOfDay(for:date)
        guard let dayEnd = calendar.date(byAdding:.day,value:1,to:dayStart) else {
            throw StorageFailure("unsupported_schema","Unknown selected day; nothing applied.")
        }
        let lo = dayStart.timeIntervalSinceReferenceDate, hi = dayEnd.timeIntervalSinceReferenceDate
        try requireStorage(request.end <= hi,"Edit crosses selected day; nothing applied.","unsupported_schema")
        var open: [String:Double] = [:], result: [StoredSession] = []
        for row in ordered(records) {
            guard row.state == 1, let event = try? AppUsageProto.decode(row.payload) else {
                try requireStorage(row.timestamp < lo || row.timestamp >= hi,
                                   "Unknown selected-day AppUsage event; nothing applied.","unsupported_schema")
                continue
            }
            if event.opening {
                if let prior = open[event.bundle] {
                    try requireStorage(row.timestamp < lo || prior >= hi,
                                       "Ambiguous selected-day AppUsage starts; nothing applied.","unsupported_schema")
                }
                open[event.bundle] = row.timestamp
            } else if let start = open.removeValue(forKey:event.bundle) {
                for (a,b) in [(max(start,lo),min(row.timestamp,request.start)),
                              (max(start,request.end),min(row.timestamp,hi))] where a < b {
                    result.append(StoredSession(bundle:event.bundle,start:a,end:b))
                }
            }
        }
        // Unclosed sessions do not establish a known end, so add no coverage.
        return result
    }
    static func usage(_ original: Data, request: ApplyRequest) throws -> Data {
        let source = try Segment.parse(original)
        var open: [String:Double] = [:], outside: [UsageEvent] = []
        for row in ordered(source.records) where row.state == 1 {
            guard let event = try? AppUsageProto.decode(row.payload) else {
                try requireStorage(row.timestamp < request.start || row.timestamp >= request.end,
                                   "Unknown AppUsage event intersects edit; nothing applied.","unsupported_schema")
                continue
            }
            if row.timestamp < request.start {
                if event.opening { open[event.bundle] = row.timestamp }
                else { open.removeValue(forKey:event.bundle) }
            }
        }
        // Close only the latest still-open pre-day start for each bundle. Fully
        // closed historical sessions are untouched. Never alter the Swift reader.
        for bundle in open.keys.sorted() {
            try requireStorage(open[bundle]! <= request.start-0.001,
                               "A pre-day start is too close to the boundary; nothing applied.","unsupported_schema")
            outside.append(UsageEvent(opening:false,time:request.start-0.001,bundle:bundle))
        }
        // Preserve the portion after the requested interval of a real crossing
        // session, not an invented ongoing/future session.
        for session in try pairUsage(source.records.compactMap { row in
            guard row.state == 1, var event = try? AppUsageProto.decode(row.payload) else { return nil }
            event.time = row.timestamp; return event
        }) where session.start < request.end && session.end >= request.end && session.end > request.start {
            if session.start < request.end && session.end > request.end {
                outside.append(UsageEvent(opening:true,time:request.end,bundle:session.bundle))
            }
        }
        var result = try Segment.parse(GeminiIOSRoute.rewrite(original,request:request,locks:false))
        for event in outside { result.records.append(SegmentRecord(timestamp:event.time,payload:try AppUsageProto.encode(event))) }
        result.records = ordered(result.records)
        return try result.encoded()
    }
}

extension NativeStorage {
    /// Conservative multi-segment rule. Old closed history is supported, but
    /// crossing/overlapping segments require a proven native pairing model.
    private func validateOlderUsage(_ paths: [URL], _ request: ApplyRequest) throws {
        for path in paths.dropLast() {
            let rows = try Segment.parse(boundedBytes(path)).records
            try requireStorage(!rows.contains { $0.timestamp >= request.start },
                               "An older AppUsage segment overlaps this edit; nothing applied.","unsupported_schema")
            var open = Set<String>()
            for row in NativeAggregates.ordered(rows) where row.state == 1 {
                guard let event = try? AppUsageProto.decode(row.payload) else { continue }
                if event.opening { open.insert(event.bundle) } else { open.remove(event.bundle) }
            }
            try requireStorage(open.isEmpty,"An older AppUsage segment has unresolved starts; nothing applied.","unsupported_schema")
        }
    }
    func prepareNativeUsage(_ request: ApplyRequest) throws -> [(URL,Data,Data)] {
        let paths = try segments()
        try validateOlderUsage(paths,request)
        var last: Double?
        for path in paths {
            let rows = try Segment.parse(boundedBytes(path)).records.filter { $0.state == 1 }
            if let low = rows.map(\.timestamp).min(), let high = rows.map(\.timestamp).max() {
                if let last { try requireStorage(low > last,"AppUsage segments overlap; nothing applied.","unsupported_schema") }
                last = high
            }
        }
        let path = paths.last!, old = try boundedBytes(path)
        return [(path,old,try NativeAggregates.usage(old,request:request))]
    }
    func prepareBacklight(_ request: ApplyRequest) throws -> [(URL,Data,Data)] {
        let paths = try backlightSegments()
        guard let path = paths.last else { return [] } // host fixtures only
        let chunks = try paths.map { try Segment.parse(boundedBytes($0)).records }
        for rows in chunks.dropLast() {
            try requireStorage(!rows.contains { $0.timestamp >= request.start },
                               "An older Backlight segment overlaps this edit; nothing applied.","unsupported_schema")
        }
        let history = chunks.flatMap { $0 }
        // Overlapping segment time ranges have ambiguous native tie ordering.
        var last: Double?
        for rows in chunks {
            let active = rows.filter { $0.state == 1 }
            if let low = active.map(\.timestamp).min(), let high = active.map(\.timestamp).max() {
                if let last { try requireStorage(low > last,"Backlight segments overlap; nothing applied.","unsupported_schema") }
                last = high
            }
        }
        let old = try boundedBytes(path)
        let usagePaths = try segments()
        try validateOlderUsage(usagePaths,request)
        let usageRows = try usagePaths.flatMap { try Segment.parse(boundedBytes($0)).records }
        let preserved = try NativeAggregates.preservedUsage(usageRows,request:request)
        return [(path,old,try NativeAggregates.backlight(old,history:history,request:request,preserved:preserved))]
    }
}
