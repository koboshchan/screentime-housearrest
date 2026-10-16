# Screen Time Editor

A native, local Screen Time editor, separated from the original research tools.

## Layout

`macOS/` contains the native Mac application and guarded local storage engine.

`iOS/` contains the native iPhone application and RootHide helper/package sources. Package and privilege support must be verified against the actual jailbreak before installation. A RootHide bootstrap and a full jailbreak are not interchangeable.

The original research is preserved outside this project in private, verified backups. The project contains only the macOS and iOS platform directories. Neither app imports or executes the historical research.

## Safety

The Mac app detects the installed macOS version and System Integrity Protection status automatically. It has no remote target and never invents sessions when a read fails. Editing takes place in memory until Apply is confirmed.

Every apply must create and verify a new private backup before modifying a store. A failed backup, stale read, malformed segment, unsupported schema, or missing permission must block the write. A successful file write is not proof that Apple's Screen Time UI has refreshed.

Private Apple storage formats are not stable APIs. Support is limited to the layouts explicitly validated by the storage engine. Permission errors are reported, not worked around by disabling SIP.

## Development

Use `make macos` for the Mac app and `make test` for safe fixture-only tests. Follow `iOS/README.md` for the RootHide package once present.

Do not run the original scripts against live devices as part of a build or test. Do not publish the private archive, backups, personal usage records, screenshots, signing material or credentials.

No live Screen Time modification is performed by compilation or unit tests.
