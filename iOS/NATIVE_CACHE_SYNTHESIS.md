# Native baseline and category preservation

Apply requires matching native Daily and enclosing Weekly baselines. If Local is missing these for today's full native calendar day, it can promote validated same-device native Cloud baselines. It never reconstructs Daily or Weekly from sparse Hourly observations. Missing history is unknown, not zero. Weekly per-app values retain their native outside-selected-day contribution and only replace the selected-day contribution.

Existing category aggregate values are left untouched, including unequal values and web data. Category and app fields other than application duration stay intact. Segment totals are app sums including overlap. Categories may therefore be stale, by explicit user choice. Newly required hourly categories start at zero rather than borrowing another interval's aggregate.

Future refresh metadata is the normal Gemini bypass, not proof of unsafe provenance. A verified Surface archive explicitly recording the baseline as absent, combined with exact reconstruction of the old identity-stripped synthesized output, rejects a known legacy synthetic baseline. Native regeneration is not blanket rejected just because an older absence archive exists. No device Apply or restore is part of release verification.

The production planner has no HOST_STORAGE_TEST safety bypass. The host fixture constructor only supplies disposable filesystem paths; it invokes the identical planner and guards. Tests exercise valid unequal native categories, byte-equal aggregate and unrelated fields, weekly outside-day deltas, missing baselines before writes, longer future timestamps, and verified legacy-synthesis provenance.


The Cloud fallback is restricted to today. LocalDeviceIdentifier, the unique matching Cloud account/device path, Local Hourly device/user metadata, and securely decoded CloudKit record identities must agree. Daily and Weekly metadata must have the same nonfuture refresh timestamp from today. Every elapsed day in the native week must have a native Daily record, and their per-app sum must reconcile exactly with Weekly. Missing earlier days and unexplained future contributions fail closed; an uncovered historical day does not block a covered today.

Promotion strips CloudKit record identities and uses the Local envelope without modifying Cloud. Existing category aggregates and outside-selected-day weekly app contributions remain unchanged. Cloud input hashes, local device identity and absent destination paths are included in the verified backup/revision inventory. Disposable production-path tests verify creation absence, subsequent writes and exact restoration; release checks never Apply on a device.

Trusted native per-app/category templates remain required. A valid Cloud baseline does not authorize inventing an absent app's category. Read-only XS Max verification accepted Oct19's Cloud day/week while rejecting Oct17 independently; the requested App Store plus Calculator plan still fails closed because their native templates are absent from current caches. Two verified backup archives contain an App Store template but no Calculator template. No device Apply was performed.
