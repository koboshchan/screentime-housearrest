VM permission diagnosis and timeline anchoring, October 16 2026

Read-only SSH diagnosis on lume@100.124.69.91 verified macOS27.0.1 26A434, SIP disabled, app process UID501, bundle app.screentimeeditor.macos at /Users/lume/Desktop/ScreenTimeEditor.app. System TCC database queried read-only has kTCCServiceSystemPolicyAllFiles grant auth_value2/auth_reason4 for that app bundle. It also grants sshd-keygen-wrapper. No standalone Python FDA row was present.

The concrete failure is ordinary filesystem access: /private/var/db/biome/streams is owned _biome:_biome mode0700, with no ACL granting lume entry. lume is not _biome. ls cannot traverse restricted. App launches fixed /usr/bin/python3 at the same UID, with no installed privileged helper. FDA and SIP disabled do not supply the missing discretionary filesystem privilege. User-specific Screen Time records can load while system reset stores remain inaccessible. We did not execute Apply, change TCC, permissions, install a helper or elevate.

Reset prepare now translates this specific pre-mutation PermissionError into system_store_permission_denied, explaining the separate privilege requirement and no storage changes. User-cache denials become permission_denied with FDA guidance. No fallback success, implicit elevation, chmod, reset disabling, write mechanism change or bypass was added. Tests verify both failures precede opening the database.

Apply now shows a native help sheet for permission denials, keeps edits, and offers Open Full Disk Access Settings. It distinguishes system Biome privilege denial from privacy permission guidance rather than promising FDA will fix _biome ownership. It names the signed app, not globally trusted Python. Technical details remain available. No auto-retry.

Timeline content now fills at least the scroll viewport with top-leading alignment and a top-leading default scroll anchor. This prevents short rows being vertically centered in a tall bidirectional NSScrollView. Existing drag mapping and zoom are unchanged.

115 Python tests, 27 XCTest plus 16 Swift Testing tests, release build, macOS26 minimum and deep/strict signature pass. Fixture NSHostingView captures inspected timeline-top-dark.png, macos-fixture-system-permission-dark.png and macos-fixture-fda-permission-light.png in /home/kit/out/screentime-apply-fix/. No huge space above rows and both permission sheets have legible unclipped text/buttons.

App rebuilt on host Mac only at ~/screentime-housearrest/macOS/build/ScreenTimeEditor.app. No VM app replacement or real usage Apply was performed. Actual SIP-off reset still requires an authorized privileged mechanism which is not installed; this change fixes diagnosis/UI, not that privilege boundary.
