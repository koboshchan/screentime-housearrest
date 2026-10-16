# Source-change override

Apply still detects a revision mismatch and does not write automatically.
The editor now presents a native SwiftUI alert, "Screen Time data changed since
you loaded it", with Cancel, Reload and Override.

Cancel keeps the draft without writing. Reload explicitly replaces the draft
from disk. Override sends explicit boolean consent to apply those edits against
the current source, not the previously loaded revision.

The backend reads the current revision, prepares against the current stores,
takes a new verified backup, independently verifies that backup against the
CURRENT revision, and checks the source still matches it before invoking the
writer. An old loaded revision no longer refuses an explicitly overridden apply.
If the current source changes during backup preparation, the backup no longer
covers it and the operation fails without calling the writer. Override never
bypasses backup or input/schema/capacity validation. Existing partial-write
reporting and logout guidance are unchanged.

Validation uses temporary synthetic stores and throwaway IPC fixtures only.
90 Python tests and 32 Swift tests pass. Added backend checks prove a stale
override snapshots the current revision, then applies; both snapshot and
independent verification failures never invoke the writer; malformed consent
is refused; a source change after backup never invokes the writer. UI-model
tests cover the alert trigger and Cancel, Reload, Override and backup-failure
paths. No live Apply, backup, restore or usage write was executed.

The release app was rebuilt at macOS/build/ScreenTimeEditor.app using persistent
certificate 5BAC8837B31A6449CA39EFA3CB494F24AD366428. Strict signature verification,
certificate-anchored designated requirement, byte-for-byte backend resource
comparison, and macOS 26 minimum deployment validation pass.
