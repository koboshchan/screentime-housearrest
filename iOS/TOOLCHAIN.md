# RootHide build and offline verification

Build locally with `python3 iOS/package.py`. This invokes the real RootHide
Theos application/tool rules and package scheme, signs both arm64 iOS 18.0
executables using ldid, and checks the resulting Debian archive. It does not
install anything, contact an iOS device, or execute either iOS binary.

The default fork location is `~/theos-roothide`. Override with
`STE_THEOS=/path/to/roothide/theos python3 iOS/package.py`.
Use the Python entrypoint for packaging; it first signs the app, reads its
CDHash, and compiles the C caller-auth helper with that exact pin. Direct
make without a pin builds a helper that refuses callers.
Homebrew tools must be on PATH.

The official fork was installed by a recursive git clone, after reading its
installer rather than executing it. This avoids changing shell profiles,
Xcode selection, or system paths. No sudo was used.
Inspected fork commit cfba89a53a05b4a1b822121158acc3669c20602f.
Submodules supply RootHide headers and link libraries.
Existing Xcode iphoneos SDK is used; no downloaded patched SDK is required by
the current source.

Host tools used are Homebrew ldid-procursus 2.1.5-procursus7_2,
dpkg 1.23.11 and GNU make 4.4.1. The package uses the RootHide architecture
identifier iphoneos-arm64e, while the actual Mach-O architecture is arm64.
These are different concepts.

The toolchain's dm.pl archive builder produced root/wheel *names* but retained
host numeric uid/gid 501/20. The checked-in dpkg-deb wrapper instead invokes
`dpkg-deb --root-owner-group`, ensuring real numeric uid/gid 0/0 without
changing host file ownership.

The package places ScreenTimeEditor and the bundled stehelper under
/Applications/ScreenTimeEditor.app relative to the RootHide bootstrap.
RootHide's package manager handles the randomized installation root and
generated .jbroot links. No /var/jb path or guessed link is created here.

Both executables have the four baseline entitlements specified by the official
RootHide developer documentation. These do not establish uid 0, authenticated
caller identity, or runtime access to protected storage. The helper is 0755,
not setuid; no launch daemon or maintainer script grants privileges.
The native helper source now authenticates its parent executable against its
bundled app path and the build-time CDHash pin. This package still does not
grant uid 0; changing the launch privilege requires separate review.

verify_package.py extracts with dpkg-deb into a temporary directory and checks
numeric archive ownership, absence of setuid/setgid and unexpected links,
metadata, actual iOS 18 minimum load commands, the embedded ldid entitlements,
and all SHA256 CodeDirectory page hashes plus the entitlement special slot.
Apple codesign --verify reports these ldid pseudo-signatures as not signed;
that is not an Apple distribution signature. Offline hash/entitlement checks
do not prove acceptance by a particular jailbreak or device.

No iOS device runtime, installation, privileged access, live read, or usage
write is verified by packaging. Do not describe a successful package build as
a successful device test.

Official references read in full for this work are
https://github.com/roothide/Developer
https://github.com/roothide/Developer/blob/main/roothide.md
https://github.com/roothide/Developer/blob/main/interface.md
https://github.com/roothide/Developer/blob/main/entitlements.md
