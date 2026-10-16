Local backend and restored writer

Run python3 -m unittest discover -s macOS/BackendTests -v from the repository.
All tests use temporary synthetic stores. No tests access live Screen Time data.
The current suite has 72 passing tests on Mac Python and no added dependencies.

backend.py loads its sibling original_local.py. Both files must be bundled as
resources. The module is adapted from scripts/inject_local_mac.py in the verified
private backup dated 20261016-054202. It has no import-time execution, credentials,
remote access, username fallback, process termination or daemon restart.

JSON stdin commands are status, read, and apply. Apply includes revision,
dayStart/dayEnd in Cocoa seconds and sessions containing id/bundle/start/end.
Day boundaries support 23/24/25-hour days; edits must be clipped to that day.
Status/read expose canApply true and supportedWriters [original_local]. Actual
permissions, malformed data, schema and fixed segment capacity errors are reported
specifically. Historical unmatched events are warnings, never demo sessions.

Apply validates the revision, preflights the serialized latest AppUsage segment
and SQLite insertion columns, then creates a private snapshot using the SQLite
backup API. Independent verify_backup checks inventory, manifest digest, file
hashes, SQLite integrity and private sealed permissions before invoking the
writer. Backup/verification failure never invokes it. A second revision check
rejects changes during the snapshot. There is no backup or writer execution on
ordinary read/status. No real apply or live backup was run during development.

The original mechanism writes the latest AppUsage segment and deletes/reinserts
overlapping knowledgeC /app/usage rows using Z_ENT=1/Z_OPT=1. Crossing sessions
retain their outside-day portions in both stores. The builder checks all payload
and footer bounds before any writes. Long bundle identifiers use proper varints.
Other streams are preserved. Successful apply reports SUCCESS_LOGOUT_REQUIRED,
logoutRequired true, backupPath and warnings. No processes are terminated.

Concrete original limitations remain. Only the latest segment is changed; older
segments may retain overlapping history. Z_ENT=1 is the original writer behavior,
not schema-independent entity discovery. Native UI refresh and cross-device
aggregation are not verified. Biome and SQLite are not one atomic transaction.
A writer error reports possible partial changes and the verified backup location;
it does not claim automatic rollback. Sealing is not immutable against the owner.
Concurrent Apple writers can still race after the final revision check.

Database/WAL hashing streams 1 MiB chunks without the 64 MiB segment cap. It
checks fd/path identity, size and timestamps before/after reads and rejects
symlinks, nonregular files, growth and truncation. Segment parsing remains capped
at 64 MiB. SQLite validation iterates SELECT 1 instead of allocating unused rows.
Large snapshot database hashing/verification streams; tests cover sparse files,
a real large WAL, valid large SQLite backup and corruption above 64 MiB. Sparse
hashing peak Python allocation is tested below 4 MiB. Existing INVALID/COMPLETE,
permission, integrity, concurrent change and symlink rejection tests remain.

SSH live knowledgeC/WAL reads were denied by macOS privacy permissions. Parent
must verify live read in the authorized native GUI after bundling both modules.
