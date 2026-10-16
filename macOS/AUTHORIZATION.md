# Local authorization and observed denial

Apple requires the user to explicitly add an app for Full Disk Access in System Settings. This app must not request, embed, store or pipe an administrator password; it must not edit TCC databases, reset permissions, grant itself access or disable SIP.

Build with ./build.sh, then open build/ScreenTimeEditor.app locally in Finder. If a protected-store read is denied, use the app's Open Settings button, then Privacy & Security > Full Disk Access. Use Add to choose that exact signed app, enable access, quit and reopen the app, and retry loading. This is a user-controlled authorization step, not an automatic grant. An ad-hoc rebuild changes the code identity and may require renewed approval. Real store reads remain the capability test; permission settings alone are not proof of readable or supported schemas.

The read-only backend uses /usr/bin/python3, fixed bundled source, JSON stdin and no shell/sudo. Its PermissionError classification covers traversal, directory enumeration and individual segment reads. Denied access never creates demo sessions or enables apply. Backup tests use synthetic temporary fixtures, not live usage stores.

The observed SSH-launched backend read was denied with EPERM in the Biome ScreenTime.AppUsage directory. This does not establish the native signed application's TCC attribution. Apple documents a separate Remote Login setting named Allow full disk access for remote users. It has not been enabled or changed here. Do not grant broad remote access merely to make SSH testing pass.

Even after read authorization, apply stays disabled because no coordinated, certified multi-store writer/rollback exists. No actual usage records are written.

Official references checked October 16, 2026

https://support.apple.com/en-in/guide/security/secddd1d86a6/web
https://support.apple.com/guide/mac-help/change-privacy-security-settings-on-mac-mchl211c911f/mac
https://support.apple.com/guide/mac-help/allow-a-remote-computer-to-access-your-mac-mchlp1066/mac
