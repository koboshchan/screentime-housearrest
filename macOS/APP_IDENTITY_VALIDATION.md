# Native app identity

Timeline lanes, session rows, inspector identity, block tooltips and accessibility
labels display installed app names. NSWorkspace resolves the exact stored bundle
ID to the installed application URL; Bundle reads its localized display name,
then bundle name; NSWorkspace supplies the native icon. Missing applications
retain the exact raw bundle ID with no invented icon. Names never replace
stored identifiers or change backend requests. The inspector retains an editable
Bundle ID field. Resolved identities are cached for the current process.

90 Python and 37 Swift tests pass. Five new tests cover display-name priority,
bundle-name fallback, absent applications, missing names and real Finder
resolution through NSWorkspace. Release app rebuilt at the existing path with
the persistent signing certificate; strict certificate requirement verification
passes. Deployment validation confirms macOS 26.

Native light/dark identity-only offscreen renders were visually inspected:
Finder and Safari resolve correctly with native icons; unknown IDs remain raw.
No clipping. Empty icon slots preserve label alignment. Snapshot harness now
includes AppIdentity.swift. These are not full-window screenshots and do not
claim live timeline verification. No live usage writes, backup/apply or push.
