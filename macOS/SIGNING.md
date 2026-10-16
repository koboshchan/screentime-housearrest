# Persistent local signing

Future builds use the persistent Screen Time Editor Local Signing certificate,
SHA-1 5BAC8837B31A6449CA39EFA3CB494F24AD366428. Its private key is in a dedicated
keychain under ~/Library/Application Support/ScreenTimeEditor/Signing.
The directory and password file are owner-only. No key, password or keychain
is tracked in git. Do not delete or regenerate these files between builds.

The existing Apple Development certificate was present but a disposable test
could not use its locked login-keychain private key from the remote session
(errSecInternalComponent). The login keychain and its access controls were not
modified. Instead, a ten-year local self-signed code-signing identity was created
in the dedicated keychain. Only that new key's codesign access was configured.
No trust root was installed and no system trust settings were changed. This is
a local development identity, not notarization or distribution signing.

scripts/signing.sh preflights the fixed identity before build.sh compiles or
replaces the app. A missing identity fails closed; it never generates a new
certificate or falls back to ad-hoc signing. SIGN_IDENTITY may explicitly select
another valid certificate by its exact SHA-1 fingerprint.

Tests signed a disposable app twice with changed resources and verified both
signatures and an unchanged certificate-anchored designated requirement:
identifier "app.screentimeeditor.macos" and certificate leaf =
H"5bac8837b31a6449ca39efa3cb494f24ad366428".
The second version also passed explicit verification against the first version's
requirement. No temporary app was launched.

The installed build was not rebuilt, re-signed, launched, or otherwise changed.
A complete SHA-256 file manifest, including signature files, matched before and
after setup. Current Full Disk Access settings were not touched.

At the next requested rebuild, switching from the old ad-hoc identity to this
certificate may require one final Full Disk Access re-add. Subsequent builds
keep the same certificate-based identity. Actual FDA retention across future
rebuilds has not yet been exercised because the current app is intentionally
untouched.
