Original local backend restoration, October 16 2026

The private 20261016-051831 backup and git history were inspected read-only. The original local Swift loadLocalData reader parses each user's ScreenTime.AppUsage SEGB and pairs decoded start/stop events. Its scripts/inject_local_mac.py writes only the newest user-owned AppUsage segment and the user's knowledgeC database. It does not access system Biome or clear DeviceActivity. The original remote Mac writer is different: it used root via sudo, not a local privileged helper. No historical local administrator-prompt/helper mechanism was found. Credential-bearing historical sources were not copied into this project.

The later system Backlight/cache reset was accidentally selected solely because SIP was disabled. Shipping CLI Apply now always uses original_local and the verified usage-backup-first route regardless of SIP. Legacy reset logic is retained only behind explicitly injected Python fixture reset_paths; shipping CLI cannot accept or enable these paths. status advertises original_local only. No privileged helper, password prompt or permission change was added. Actual usage Apply still requires explicit user approval. Logout-required refresh semantics remain conservative rather than claiming the native UI refreshed.

Independent live VM read-only verification as lume on macOS27.0.1 (26A434), SIP off, compared the unmodified original SEGBV2.swift parser plus original per-file pairing algorithm against the new backend. Exact session multisets matched: 57 complete sessions, 5 Safari sessions. Evidence vm-original-reader-parity.json. Original full SwiftUI app was not launched; neither reader executed its writer.

Safari's apparent disappearance was display filtering: today's four complete Safari sessions were 28.607,30.664,10.825,59.753 seconds, all individually below60. Filtering now uses the app's combined daily duration, so genuine minutes split into short sessions remain visible. Apps with under1min total remain hidden by default; toggle Show apps under1m total restores them. Filtering never changes stored sessions or Apply payload.

Latest UI offscreen read-only captures ran on the actual VM with the new backend, not fixtures. Load had46 day-clipped sessions, no load error, SIPdisabled, canApplytrue. Safari is visible and the previously fixed top anchoring is correct. Light and dark inspected, no clipping. Evidence /home/kit/out/screentime-apply-fix/vm-original-route-{light,dark}.png. These are NSHostingView captures, not display screenshots. Native System Settings aggregates and actual Apply are not independently verified.

117 Python tests,28 XCTest plus16 Swift Testing tests pass. Added regression covering all SIP states without system access/subprocess calls, valid verified backup, and Safari's four actual durations. Release build and fixture snapshots pass. App path ~/screentime-housearrest/macOS/build/ScreenTimeEditor.app on host Mac. No push, VM app replacement, permissions changes or real usage Apply. Private backup untouched. Owned read-only QA files removed from VM after evidence downloaded.

Historical source hashes
inject_local_mac.py 20d31b9d3be60c762098727de5ca307663992361781461a24e20d6b7b8f3bd2e
SEGBV2.swift 319ff014c1f734c859cc66b42a3f7fc18bf79a8a90a2c86128d536ca2de05364

This supersedes PERMISSION_VALIDATION.md's description of an active SIP-off system reset requirement. System ownership diagnosis remains true, but the restored original local route does not access that folder.
