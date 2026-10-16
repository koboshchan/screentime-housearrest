# Real-store reader compatibility, October 16, 2026

Read-only footer inspection in the FDA-authorized native GUI context found state 1 = 45,224 records, state 3 = 1,183 records, and state 4 = 3 records. No other values occurred in that scan. No raw payloads, app identifiers or usage intervals were exported.

Compared against the hash-verified 054202 private backup, SEGBV2.swift retains arbitrary non-active states as opaque records (or empty payloads), and ScreenTimeStore.swift consumes only state 1. Restored that behavior, including not resetting the payload offset on zero end offsets. The temporary-store segment builder now preserves empty payload semantics for every non-active state, not only state 0.

The next native read exposed another added strict check absent from the original, footer/protobuf timestamp equality. Original ScreenTimeStore uses footer timestamps and skips undecodable payloads. Restored those read semantics rather than aborting the entire load. Active payload CRC, footer capacity, file stability, verified pre-apply backups and revision safeguards remain in place.

The fixed backend read successfully through the previously authorized native app at 2026-10-16T13:11:34Z, QA PID 25604. Report showed 42 selected-day sessions, a nonempty revision, no load error, no permission error, and no dirty edits. Existing historical pairing warnings remain. No Apply, live backup, restore, usage writes or permission changes were performed.

Validation completed with 82 Python temporary-store tests, 12 EditorModel XCTest cases and 16 core Swift tests, release app build, strict signature verification, deployment validation and secret audit (50 files, zero findings). Regressions cover state 3/4, arbitrary non-active states, zero-end offset preservation, opaque payload round trips, footer timestamps and skipping malformed usage payloads. Add is the existing native SwiftUI toolbar Button, unchanged.

Rebuilt at the same macOS/build/ScreenTimeEditor.app path with the same bundle identifier and ad-hoc signing mode. Source resources match the built resources exactly. macOS ad-hoc signing uses a cdhash designated requirement, and resealing changed it from 38693f87ef26f19e3bb3b7c7786c7e1a52cbcc75 to the rebuilt hash. The final newly signed native GUI read again returned Full Disk Access denial. The earlier successful read proves the parser fix on real data, but the final signed app needs its FDA entry renewed. No attempt was made to alter TCC or weaken signing to retain access.
