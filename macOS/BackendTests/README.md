Backend contract and verification

Run `python3 -m unittest discover -s BackendTests -v` from macOS/.
Only temporary fixtures are used. No test calls production apply on real paths.

The executable reads one JSON object from stdin and writes one JSON object to
stdout. Commands are {"command":"status"}, {"command":"read"}, and
{"command":"apply","revision":"<64 lowercase hex>","dayStart":0,"dayEnd":86400,
"sessions":[{"id":"unique","bundle":"com.example.App","start":100,"end":200}]}.
All session and boundary timestamps are Cocoa seconds. Apply validation requires
sessions clipped to the selected day (23/24/25-hour days accepted).
Nonzero exit returns {"error":"human-readable message","code":"machine_code"}.

status returns macOS, build, sip (enabled/disabled/unknown), sipDetails,
warnings and canApply:false. Detection failures are not interpreted as SIP enabled.
read returns sessions, revision, warnings and canApply:false, or a nonzero error.
Events pair across all local segments. CRC failure, unsupported schema, missing
permissions, malformed protobuf and unmatched ends are errors, never demo data.
Unclosed live starts produce a warning and no manufactured end timestamp.
No remote access, child shells, daemon control, sync calls or legacy imports.

Current production apply is intentionally BLOCKED. It validates the request,
performs a complete read, checks the revision, then returns
unsupported_write_layout without changing any store. There is no production
write path or successful apply response. The private undocumented Apple layouts
and live Apple writers do not provide certified cross-store atomicity.
The UI must not turn this into an enabled Apply button or a success banner.
This is an actual guarded read backend, NOT a completed storage mutation engine.

The verified_backup helper is fixture-tested but NOT invoked by blocked apply.
It copies all parsed AppUsage sources and uses SQLite's backup API for a
consistent WAL-aware knowledgeC snapshot, verifies hashes and integrity,
records a manifest and metadata, then permission-seals files 0400/dir 0500.
Permission-sealed does NOT mean filesystem-immutable against the owner. No
immutable-backup or multi-store rollback guarantee is claimed.
A future writer must certify exact CoreData Z_ENT/Z_PRIMARYKEY allocation,
preservation of every other stream, transactional rollback and live writer
coordination before enabling writes. These are deliberately not guessed.

Native verification on the Mac reported macOS 27.2 build 26B5091g, SIP enabled.
Native read honestly failed Operation not permitted at the AppUsage directory.
All 27 fixture tests passed on both Linux and macOS. No real apply was executed.

Bounded reader update (2026-10-16)

Database/WAL revision hashing now streams 1 MiB chunks without the segment size
cap. Each scan reads only the initial file length and rejects growth, truncation,
metadata changes, inode replacement, symlinks and nonregular files. Segment
parsing still has its 64 MiB in-memory format limit. SQLite usage validation
iterates a constant-sized SELECT 1 cursor instead of allocating unused rows.
Backup copy/digest verification also streams; the SQLite backup API remains the
only database copy mechanism, with integrity, INVALID/COMPLETE and sealing checks
preserved. Production apply stays blocked and never calls backup.

The full current suite has 63 passing tests on Mac Python, including sparse files
and database/WAL files above 64 MiB, a real large WAL read, a valid large database
backup, corrupted large backup rejection, concurrent changes, descriptor/path
replacement and symlink/FIFO rejection. The sparse hash memory test requires peak
Python allocations below 4 MiB. No external dependencies were added.

A read-only hash attempt through SSH could not access current knowledgeC.db or
its WAL (Operation not permitted). GUI real-data verification must therefore be
performed separately in the authorized native app after rebundling this backend.
No live backup, write, apply, install, permission change or deployment was done.
