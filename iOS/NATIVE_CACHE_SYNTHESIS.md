# Native baselines and overlapping app sums

Apply requires matching native Daily and enclosing Weekly baselines. If Local is missing these for today's full native calendar day, it can promote validated same-device native Cloud baselines. It never reconstructs Daily or Weekly from sparse Hourly observations. Missing history is unknown, not zero. Weekly per-app values retain their native outside-selected-day contribution and only replace the selected-day contribution.

Category and segment duration totals are recomputed as app sums including overlap, without a per-hour or per-day cap. Web data and all unrelated category/app fields remain intact, but web durations do not add duplicate time. Newly introduced categories use their app sum instead of zero.

Future refresh metadata is the normal Gemini bypass, not proof of unsafe provenance. A verified Surface archive explicitly recording the baseline as absent, combined with exact reconstruction of the old identity-stripped synthesized output, rejects a known legacy synthetic baseline. Native regeneration is not blanket rejected just because an older absence archive exists. No device Apply or restore is part of release verification.

The production planner has no HOST_STORAGE_TEST safety bypass. The host fixture constructor only supplies disposable filesystem paths; it invokes the identical planner and guards. Tests exercise valid unequal native categories, exact summed category aggregates and byte-equal unrelated fields, weekly outside-day deltas, missing baselines before writes, longer future timestamps, and verified legacy-synthesis provenance.


The Cloud fallback is restricted to today. LocalDeviceIdentifier, the unique matching Cloud account/device path, Local Hourly device/user metadata, and securely decoded CloudKit record identities must agree. Daily and Weekly metadata must have the same nonfuture refresh timestamp from today. Every elapsed day in the native week must have a native Daily record, and their per-app sum must reconcile exactly with Weekly. Missing earlier days and unexplained future contributions fail closed; an uncovered historical day does not block a covered today.

Promotion strips CloudKit record identities and uses the Local envelope without modifying Cloud. Category aggregates follow the same app-sum policy; outside-selected-day weekly app contributions remain unchanged. Cloud input hashes, local device identity and absent destination paths are included in the verified backup/revision inventory. Disposable production-path tests verify creation absence, subsequent writes and exact restoration; release checks never Apply on a device.

Trusted native per-app/category templates remain required. A valid Cloud baseline does not authorize inventing an absent app's category. Read-only XS Max verification accepted Oct19's Cloud day/week while rejecting Oct17 independently; the requested App Store plus Calculator plan still fails closed because their native templates are absent from current caches. Two verified backup archives contain an App Store template but no Calculator template. No device Apply was performed.


## Older iOS 18 refresh safety

The XS Max runs iOS 18.3 beta 22D5034e. Its Preferences crash stack is Foundation DateInterval.init(start:end:), called at DeviceActivity offset 342284. A read-only extraction matched DeviceActivity UUID 7D88FD34-405A-31D5-A10C-1FC33F39ABF6 exactly. That refresh path logs a query start after the current date but continues to construct the interval. The verified 18.6.2 reference instead skips an out-of-bounds refresh.

Apply and standalone cache planning now refuse iOS 18.0 through 18.5 before any backup or writes. This is a safety denial, NOT a functional replacement for the future-date hold on those systems. Silently clearing the hold would permit native refresh to erase edited totals. Previously written future metadata is not repaired by installing this build, and no device Apply or repair was performed. Older-build support needs a separately validated refresh strategy.
