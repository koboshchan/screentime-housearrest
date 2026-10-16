# iOS source status

This is an experimental source scaffold, not a working Screen Time editor or an installable RootHide package. The SwiftUI editor and pure session rules compile, but no live session reader, schema adapter, writer, backup, restore, root launch mechanism, or authenticated privileged transport is implemented. Empty state is not a successful live read. No demo sessions are supplied.

The helper is a no-I/O protocol stub. Every recognized operation returns integration_unavailable and exits 2, even if run as root. Unknown operations and extra arguments return bad_request. It does not inspect databases, read environment paths, create directories, copy SQLite sidecars, or write usage data. The app capability gate always disables apply in this build, even for a forged ready reply.

The old implementation's environment-derived backup directory and independent live DB/WAL/SHM copies were removed. Hash equality of separately copied files cannot establish a consistent SQLite snapshot. Before enabling any live operation, implement and review authenticated caller identity, privilege separation, trusted descriptor-relative no-symlink storage, a consistent coordinated SQLite/Biome snapshot with manifest completeness and permissions, schema/version validation, mandatory verified backup before apply, recovery, and device-specific tests.

## RootHide reference checked October 16, 2026

Read official Developer README, roothide.md, interface.md and entitlements.md, plus libroothide/jbroot.m. RootHide randomizes its jailbreak root; do not concatenate a guessed environment directory. The official interface is jbroot() from <roothide.h>, preferably a Swift bridging header, built against RootHide Theos or the official devkit. jbroot converts bootstrap paths to native filesystem paths; rootfs converts in the opposite direction. Neither selects the correct Screen Time database, grants root, nor authenticates a caller. The Objective-C implementation can return its original input on conversion failure, so blindly trusting any returned string would also be incorrect.

The official build scheme is THEOS_PACKAGE_SCHEME=roothide, not a guessed Debian Architecture string. Entitlements documented upstream address sandbox behavior, not a verified privileged launch contract for this app. Bootstrap and full-jailbreak capability are not interchangeable. Exact user device, jailbreak variant, version, entitlement/signing contract, transport and install layout remain unverified.

https://github.com/roothide/Developer
https://github.com/roothide/Developer/blob/main/roothide.md
https://github.com/roothide/Developer/blob/main/interface.md
https://github.com/roothide/Developer/blob/main/entitlements.md
https://github.com/roothide/libroothide/blob/main/jbroot.m

## Validation and artifacts

Run bash iOS/build.sh on the existing Xcode Mac for local compile validation. It builds unsigned arm64 iOS 15-target app/helper Mach-O files under build/UNSIGNED-COMPILE-ONLY.app, runs pure host logic tests, and runs host-only protocol tests against the new no-I/O stub. This does not establish runtime behavior on iOS. No app or helper is installed or run on a device. No existing legacy code is executed.

package.py always refuses packaging with exit 2, including --production; it emits no archive. The previous UNSIGNED-TEST.deb used an unverified architecture and was not a valid deliverable. It was removed with the task-owned generated build directory during rebuild. There is no current .deb deliverable and no artifact should be sent or installed.

RootHide Theos/devkit, signing tools and production packaging remain unresolved; no dependencies were installed for this correction. entitlements.plist is an unvalidated proposal, not applied by build.sh. No device compatibility claim is made.

Correction validation completed successfully on the Mac. 14 pure logic checks passed, all 8 host stub protocol cases passed, packaging refusal passed, and no .deb exists in build/. Both Mach-O files were inspected with vtool and report platform IOS, minos 15.0, sdk 27.2. Compilation emitted two clang incompatible-sysroot warnings mentioning macOS 27.2 while targeting iOS 15.0; the Mach-O platform inspection passed, but this warning remains unresolved. No runtime-on-device claim is made.
