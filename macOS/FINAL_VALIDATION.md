# Completed validation, October 16, 2026

The local app builds and codesign --verify --strict passes. The final app's bundled backend.py is byte-identical to source, SHA256 7fc627ec1d02db0f66a6edf68929298dbb60396ad64ae927f8286f4f0de8a572.

make test passed 47 Python backend fixture tests and 16 Swift tests. The real Swift-to-Python integration test used status/read only. It decoded macOS 27.2 (26B5091g), SIP enabled, canApply false, and permission_denied on the Biome AppUsage directory. It did not execute apply against the real backend. The apply encoding test invokes only a temporary fixture script.

The signed .app was opened using LaunchServices (/usr/bin/open -g) with exit 0. A bounded native-display capture attempt failed with exit 1, could not create image from display; no display image exists. Launch success does not establish that the native app read protected data. The actual native-login TCC/read outcome remains unverified. No remote Full Disk Access option, TCC grant or SIP setting was modified. User-controlled local authorization is documented in AUTHORIZATION.md.

The final light/dark files at build/snapshots/macos-real-light.png and macos-real-dark.png render the exact shared DetailPane after a real backend bootstrap, using offscreen SwiftUI ImageRenderer. Both were visually inspected after the collapsed Details correction: no clipping, overlap or readability issue. The sidebar and window chrome are absent. The dark background is an approximation because offscreen rendering cannot reproduce window material. These are not actual display screenshots, full-window coverage, real-session timeline tests, or interaction tests.

Both platforms refuse live apply. No certified multi-store writer/rollback exists. Independent mandatory-backup verification is tested with temporary synthetic fixtures, not claimed as a successful live backup. No usage write, injector, device installation, live backup or permission bypass was performed.

iOS final compile/model/IPC/package refusal and official RootHide environment blockers are recorded in ../iOS/STATUS.md. Missing RootHide toolchain/signing plus missing authenticated privileged integration prevent an installable package; no .deb is delivered.

Both private backups and the external private research archive remain outside this repository. The fresh pre-edit backup was independently rehashed across all 3262 manifest entries with zero file/link mismatches, regular files owner-only and backup root 0700. The earlier backup remains present. poc/ is absent.
