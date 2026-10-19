# Restored Gemini jailbreak route

## Original sources
Private backup 20261016-051831, scripts/inject_ios.py main/parse_segb_v2/build_segb_v2, ScreenTimeEditor/Sources/ScreenTimeEditor/Model/SEGBV2.swift, ScreenTimeStore.swift loadLocalData. Backup unchanged. Full standalone writer is the requested route, not the weaker applyToIOS variant that omitted knowledgeC.

## Actual shipping wiring
App Store.reload -> fixed read helper operation -> NativeStorage.readSnapshot -> GeminiSwiftReader.sessions -> original SEGBV2.parse/decodeAppUsage. Core/GeminiSEGBV2.swift is the original Swift file, with only load changed to loadUnaligned for safe native byte alignment. Strict Segment.parse bounds/CRC validation precedes original parsing. Pairing is per segment in record order, latest start wins, footer timestamp used, then sort by session start, exactly loadLocalData. Empty reads stay empty, no demo fallback. This is the same original Swift reader algorithm as macOS, not the previous generic protobuf reader.

App Apply -> authenticated helper -> NativeStorage.apply in GeminiIOSRoute.swift. Full original standalone steps mapped as follows.

1. Original killall Preferences/ScreenTimeSettingsAgent becomes fixed exact-name native process signaling after verified backup. SIGTERM replaces unsafe killall -9; no shell.
2. AppUsage parse/filter/append/build -> GeminiIOSRoute.rewrite with locks false. All selected-day records removed, selected sessions produce original trusted on/off protobuf, stable time order.
3. ScreenLocked -> same rewrite with locks true, exact 0800/0801 payloads. No synthetic boundary intervals.
4. knowledgeC -> GeminiKnowledge.swift validateGeminiSchema/replaceGemini. Original broad overlap DELETE retained (all streams). Original 25-column usage and unlocked inserts retained, including value type constants and confidence. Selected session timestamps/bundle, Calendar weekday/seconds-of-day, timezone offset, new UUID and positive per-row UUID hash replace fixed proof samples. Entity resolved from actual usage metadata, not blindly hardcoded 11. Two rows per selected session. SQLite transaction with rollback.
5. DeviceActivity Local rm-rf -> discover fixed SystemGroup Local paths, verify unchanged cache inventory and remove Local roots after backup. Absent Local remains valid on subsequent reloads.
6. Open Settings -> fixed sync then uiopen fallback via posix_spawn, no caller executable or arguments, no SSH/Python. Missing utilities return partial-apply failure with verified backup ID.

## Native transport and safety
Helper/Auth.c root/caller path/ancestor ownership/CDHash authorization remains before stdin/storage. Fixed operations only, no path or command fields. Device layout replaces rootfs SSH mount prefix; no host/password/segment ID/shared-group UUID carried over. Newest local stream segment chosen deterministically instead of fixed historical filenames; others left untouched. Existing ownership/modes retained by descriptor writes instead of forced sample chown/chmod.

Every apply, including overrides, makes and independently verifies a fresh backup of both streams, knowledgeC plus WAL/SHM/journal, all Local cache contents, metadata and absence states BEFORE stopping processes or opening a writable live SQLite handle. Revision is rechecked before writes. Backup failure prevents writes. Multistore apply is not atomic; any partial error names backup. Old rewritten backend exists only behind HOST_STORAGE_TEST for historical regression fixtures and is excluded from shipping app/helper. UI unchanged.

## Validation and honest limits
bash iOS/build.sh compiles actual arm64 iOS app/helper and runs synthetic model/IPC/auth/storage/Gemini writer/reader checks. python3 iOS/package.py builds/signs and verifies RootHide archive locally. Host fixtures use temporary synthetic files only.

No install, launch, push or live device writes. RootHide root launch, storage visibility/permissions, device SEGB/schema compatibility, fixed refresh utilities and Settings aggregation remain runtime untested. Missing full original database columns fails closed with a precise schema error rather than writing an incomplete replacement. Ready for controlled device testing only after package verification, not claimed device-proven.

## Vphone iOS18 refresh correction
The optional screentime-cli is absent. More importantly, the signed native helper
sees the stock root filesystem rather than the jailbreak shell's remapped root:
a signed, sanitized native probe returned access ENOENT and posix_spawn errno2
for /usr/bin/uiopen, while the shell's uiopen succeeded. Do not inject jailbreak
environment variables into the privileged helper to make a utility resolvable.

The final refresh now uses the existing exact-name kernel process signaling for
Preferences, ScreenTimeSettingsAgent, ScreenTimeAgent, UsageTrackingAgent and
biomed. Missing optional processes are harmless; actual signaling errors fail.
No additional cache paths or deletions were added. The successful UI response
opens the Screen Time preferences URL from the app process, not the root helper.
Original verified backup, data rewrite, cache-change check and Local deletion
remain unchanged.

On pcc-research-03-clone iOS18.6.2, ran a signed refresh-only harness containing
the same production Core sources. It succeeded without calling Apply or writing
usage stores. Opened Settings manually via shell uiopen; desktop capture showed
Screen Time Daily Average 1h35m and Updated today at2:34AM matching the device clock.
This verifies a current Settings refresh, not exact agreement with Lucas's intended
edited total (no expected total was provided). Reinstalled the verified package.

Native-total correction, October 17

The original Gemini Swift reader, three route architecture and base iOS writer remain intact. The iOS apply route now plans an additional native aggregate-input correction before making the mandatory verified backup. Nothing in this change installs or tests on a device automatically.

ScreenTime.AppUsage now closes the latest still-open pre-day start per bundle at interval start minus 0.001 seconds. Previously closed historical sessions are not closed again. Real closed sessions crossing the interval preserve their outside portions; an unproven cross-segment start/close relationship fails closed instead of guessing. Overlapping segment time ranges and older segments touching the edited interval also fail closed.

Device.Display.Backlight uses a fixed protected native local path. Its verified payload is protobuf field 1 fixed64 Cocoa timestamp and field 2 varint Boolean state. It establishes off at interval start, emits on/off for the union of all selected sessions, removes interval records and preserves outside payloads and SEGB metadata. Empty sessions mean an off interval. A past end boundary restores the original state including an exact-end event. A future end boundary never receives a synthetic on event. Unknown payloads, mismatched clocks, opaque in-interval states and ambiguous multi-segment overlap fail before backup or mutation. Only synthetic host fixture constructors may omit Backlight.

Backlight is now part of source inventory, revision fingerprints, private verified backups under backlight- names, CRC parsing, original ownership/mode inventory and checksum verification. All stream plans are serialized before backup. Current-source revision is checked again after verified backup and every descriptor write compares original bytes, length and link count. Existing caller authentication and fixed-path protocol restrictions remain unchanged. Multiple stores still cannot be committed atomically; failures identify the verified current backup.

The prior refresh-only result demonstrated daemon refresh, not correct totals. Separate caller-owned iOS18 VM experiments found that closing dangling pre-day AppUsage starts corrected native per-app totals, and rewriting Backlight then rebuilding Local DeviceActivity cache corrected the daily total. One controlled 30-minute Preferences edit produced native Preferences and daily totals of 1823 seconds, including 23 seconds of natural use. That evidence motivates this implementation; the packaged integration itself still needs caller-owned VM verification after installation. No general real-device or iOS27 total-correction claim is made.

Host validation covers union/overlap/gaps, empty edits, elapsed and future boundary rules, exact boundaries, dangling open versus previously closed history, crossing sessions, unsupported schema, CRC, multi-segment fail-closed behavior, mandatory Backlight backup metadata and corruption rejection, and a Backlight concurrent-change abort before usage mutation. Gemini reader regression checks remain unchanged.


Native apps-only total integration, October 18

Apply preserves the original Swift reader, Gemini stream writer, full knowledgeC
SQL transaction, caller authentication and fixed native path discovery. After
planning the streams, it now preflights native DeviceActivity cache replacements
before taking the same fresh independently verified full backup. It no longer
deletes Local on this route.

Hourly and Daily totals are exact sums of applicationActivities durations,
including overlap across apps. Category totals are recomputed from their app
entries only. Web details are preserved for existing segments but never added
again to category or segment totals. Larger old totals are replaced, not retained
as maxima. Weekly app totals retain the other days by subtracting the cached
edited Daily app amounts and adding the requested app amounts; inconsistent
negative deltas fail closed before backup. It does not sum Daily caches outside
the selected week.

Every requested session is clipped into its proper hourly bucket, with full-day
23/24/25-hour DST handling. Missing buckets are created only at deterministic
timestamps in the discovered Hourly directory, with O_EXCL/O_NOFOLLOW and native
template owner/group/mode. New buckets contain requested apps only, no copied
historical web/pickup data. App/category metadata comes from existing validated
native templates, not proof samples. Missing app templates, missing matching
Daily/Weekly intervals, duplicate apps/categories, overlapping segments, ambiguous
roots, symlinks and unsupported schema fail closed without writes.

After backup verification and the existing revision checks, the stream/database
writer runs as before. Cache revision is checked, then all segment replacements
are written using original-byte comparisons. Metadata is written last. The
Gemini bypass sets each granularity's lastUpdatedDate to at least
max(now, editedDayEnd) + 30 days, preserving an already later date. There are no
hardcoded proof dates, IDs, Python runtime or copied usage samples.

This future date intentionally prevents the normal DeviceActivity cache refresh
for the entire Local cache, including subsequent real usage, until that date.
Apply's reply explicitly reports the hold. Reapplying recalculates the requested
day exactly without accumulating it twice and extends the hold. No automatic
unfreeze/background refresh service is introduced.

SQLite rollback and the verified backup are unchanged. Multistore writes are
still not atomic and do not claim automatic rollback; a partial error identifies
the verified prewrite backup, whose complete directory inventory also records
which hourly files were absent. Restoring must reconcile that inventory, not just
overwrite existing files.

Host-only synthetic tests exercise 2h + overlapping 2h = 4h, >24h, exact lower and
fractional totals, web exclusion, no category doublecount, empty edits, repeat
Apply/weekly deltas, new buckets, future-metadata preservation, malformed data,
symlink/concurrent-file rejection, DST days, and production Apply with mandatory
backup and revision race detection. No live install or Settings verification of
this packaged integration has been performed.

The blanket iOS 18.0–18.5 Apply denial was removed at Lucas's request. He reports that Apply and Settings worked on this XS Max 18.3, and that a later immediate Settings crash clears after lock/unlock. That recovery does not establish the crash cause.

Post-write refresh already signals Preferences, ScreenTimeSettingsAgent, ScreenTimeAgent, UsageTrackingAgent and biomed. It now waits a bounded number of probes (101, spaced 20ms apart) for the signalled PIDs to disappear or change names, rather than acknowledging the signal itself as completion. Probe errors and exit timeouts return refresh failure, which Apply reports with the verified backup ID as a partial Apply failure. No replacement process is signalled during this wait. The same-name PID-reuse case conservatively times out.

Exit acknowledgement is not a cache-ready handshake, does not reproduce lock/unlock, and is not proof that the transient Settings crash is fixed. Synthetic barrier tests cover immediate exit, delayed exit, timeout, probe failure, multiple PIDs and invalid bounds. Live crash diagnosis still requires saved cache comparison and native Settings verification. No live Apply was performed for this revision.
