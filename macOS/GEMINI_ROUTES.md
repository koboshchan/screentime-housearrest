Gemini restoration source and adaptations

Source is private backup screentime-housearrest-private-backup-20261016-051831.
Reader sources are ScreenTimeEditor/Sources/ScreenTimeEditor/Model/ScreenTimeStore.swift,
SEGBV2.swift and Session.swift. GeminiSEGBV2.swift retains the original codec with
unaligned loads for safe Data access. GeminiSwiftReader ports loadLocalData's
lexically sorted files, per-file open dictionary, record order, footer timestamps,
replacement of duplicate starts and max(start,end) Session behavior. No fallback
demo sessions, remote access or native aggregate inference is restored.
Bounds, regular-file, size and CRC validation fail closed before parsing.
The app opts into this Swift reader; Python read before and after supplies checked
revision, schema/access validation and detects sources changing during the read.
Python transaction read remains internal validation, not the app's session source.
Untracked gemini_reader.py and its diagnostic fixtures are NOT wired or staged.

SIP on uses original_local's nonroot AppUsage and knowledgeC writer, then logout.
SIP off prompts once through the pinned signed immutable helper. User writing runs
in a separate child which irreversibly drops root; fixed system Backlight access
uses a scoped root context. The original remote script removes day records from
one HARDCODED Backlight segment, inserts each session's on/off records, clears
DeviceActivity Local, replaces overlapping app usage and isBacklit knowledge rows
with Z_ENT=1, then restarts the user's UsageTrackingAgent.
Local adaptation selects one latest lexically named Backlight segment, discovers
the current user's cache/home/UID, and does not copy SSH/password transport.
Existing AppUsage crossing-day preservation and older-segment dedup safeguards
remain. Capacity, symlink, schema and revision checks remain. These safety edits
mean this is not a byte-for-byte original script replay.
Both usage and system/cache backups are verified with final revision/preflight
BEFORE stopping any process or invoking either writer.
Cancel/failure never reloads or mutates unsaved drafts automatically.
No live Apply, administrator prompt or installation was performed for validation.
Native refresh and cross-device aggregation are unverified.
