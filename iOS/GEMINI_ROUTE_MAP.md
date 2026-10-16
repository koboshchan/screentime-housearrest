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
