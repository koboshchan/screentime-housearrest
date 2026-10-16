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

## Additional validation, no simulator installation

bash iOS/build.sh
bash iOS/Tests/snapshot.sh
python3 iOS/package.py --production

The last command MUST refuse with exit 2; it is not a packaging success. The current build script explicitly selects the macOS SDK for host tests, resolving the earlier sysroot warnings. The final rerun passed without warnings, with 14 logic checks, 8 stub protocol cases, and both iOS Mach-O platform inspections passing.

The screenshot harness uses the exact shared AccessStatusView now included in the iOS screen. It renders the real unavailable-state text with empty sessions using macOS SwiftUI ImageRenderer, without launching the shipping app, spawning the helper, reading databases, or installing anything in a simulator or device. Light and dark PNGs are under build/snapshots/. These are shared-component host renderings, NOT iOS simulator screenshots, full-screen UI tests, or timeline interaction evidence. Both images were visually inspected for readable text, wrapping, clipping and contrast; no clipping found. In-memory-only editing and discard-on-close are now explicitly disclosed.

A fresh tooling check found no theos executable, no ~/theos directory, no ldid and no dpkg-deb on this Mac. No tools were installed. Production packaging therefore cannot be validated here. The original hand-built archive has been retired rather than renamed or presented as a deliverable.

For the eventual approved toolchain setup, follow official roothide/theos and Developer instructions, then use the actual Theos package project with THEOS_PACKAGE_SCHEME=roothide make package. No such project is claimed to exist yet. Do not substitute a handcrafted Architecture field or ordinary Xcode arm64 build for the scheme. Before releasing, inspect the generated archive's control metadata and filesystem layout with dpkg-deb --info PACKAGE.deb and dpkg-deb --contents PACKAGE.deb, inspect every Mach-O's platform/load commands, verify applied entitlements and signatures using the approved signing tools, and validate RootHide's generated relocation/link behavior. The final architecture/layout must come from that verified scheme, not assumptions here. Privileged helper placement/ownership, launch method and caller authentication remain design blockers before a production package can exist. These future steps are instructions, not completed tests.

## Actual host IPC validation

The host build now compiles the actual App/HelperClient.swift with HOST_IPC_TEST, enabling a fixture executable path injection method excluded from the iOS build. Tests spawn the newly built no-I/O helper and exercise the real posix_spawn, stdout pipe, waitpid and Swift JSONDecoder path. All four operations decode a typed integration_unavailable denial with disabled read/backup/apply capabilities. All four reject extra argv as bad_request. Missing executable returns nil. These eight command cases plus missing-executable check passed, alongside the separate eight Python subprocess protocol cases and 14 model checks.

HelperClient now closes the duplicated child pipe writer and rejects signal/unknown exits or mismatched ok/exit-status replies. This validates the stub command contract, NOT root escalation, authenticated production IPC, a live reader or writer. The synchronous transport still lacks a production timeout/cancellation contract and must not be enabled for privileged live work in this state.

No existing .deb is available to parse: the invalid guessed artifact was retired. Parsing a fabricated ar/tar would not establish RootHide compatibility. Packaging remains refused until the official scheme/tooling and privileged layout are verified. No architecture-guessed archive has been recreated, executed, extracted or installed.


## Final environment check

The final read-only tool probe found THEOS set but pointing to an unverified toolchain location, ~/theos absent, ldid absent and dpkg-deb absent on this Mac. No tool installation was authorized or performed. The official RootHide docs require its Theos scheme (or an actual integrated Xcode devkit), randomized-root path conversion and generated .jbroot linkage. This project currently has neither verified scheme integration nor an authenticated root launch layout. Missing signing/packaging tools are an environment blocker; missing live transport/schema/writer integration is a separate implementation blocker. Installing tools alone will not make this a working editor.

The final rerun compiled the unsigned iOS app/helper with no warnings, passed 14 model checks, 8 real Swift host IPC cases plus missing executable, and 8 Python stub protocol cases. package.py --production refused with exit 2 and no .deb. Offscreen shared-component light/dark renders were regenerated after the plain-language and contrast correction, then visually inspected with no clipping or legibility issue. These are not device screenshots or a runtime integration test. Actual app/helper platform metadata was IOS, minimum 15.0, SDK 27.2. No device or simulator install, protected-store read, backup or usage write was performed.
