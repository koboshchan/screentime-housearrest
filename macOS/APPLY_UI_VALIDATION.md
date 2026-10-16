Apply and timeline correction, October 16 2026

The SIP-disabled branch called os.confstr('CS_DARWIN_USER_DIR') during reset discovery. Apple's Python does not expose that key in confstr_names. The same installed Python reproduces ValueError: unrecognized configuration name, while /usr/bin/getconf DARWIN_USER_DIR returns the current user's directory. This is not a VM build-variant lookup. It failed during discovery, before the usage writer or reset operations.

Discovery now calls the native getconf utility with a fixed argument and no shell. Failure, timeout, stderr, empty/relative/root/multiline/NUL results fail closed with reset_unavailable. Existing inventory, source checks, sealed usage/reset backup verification, write preflight and original writer semantics are unchanged. Nine regression tests cover this boundary; the entire backend suite passes 113 tests.

Historical unmatched start is a separate read warning about an unpaired historical Safari start event. Its pairing semantics were not changed. Warning text now has primary contrast.

The sidebar and timeline default to hiding records shorter than one minute, including records previously rounded to 0m. A checkbox and hidden-record count expose them. Revealed durations display <1m. This is presentation-only: every source session is retained in Apply, dirty checking, undo and backup. Tests prove filtered records still reach the fixture Apply request and toggling is not an edit. No automatic merging or deletion of source records.

The chart uses taller 42pt lanes, 10pt minimum bar targets, stronger grid contrast, and native 1x/2x/4x zoom with horizontal scrolling. 1x fits the day; zoomed charts show hourly labels.

Validation passes 113 Python tests, 26 XCTest tests plus 16 Swift Testing tests, release build, persistent signature deep/strict verification, minimum macOS26 verification, icon layer verification and source audit (81 files, zero findings). No dependency install.

Visual QA uses an explicit --fixture option in the non-shipping snapshot harness. NSHostingView captures correctly render native controls and scroll views, unlike ImageRenderer. Inspected dark/light detail, full sidebar hidden/shown and 4x renders. Evidence is in macOS/build/snapshots/macos-fixture-*.png and /home/kit/out/screentime-apply-fix/. These are synthetic offscreen captures, not the user's VM or real usage.

The app remains at macOS/build/ScreenTimeEditor.app. No live usage writes, cache clearing, process termination, permission changes, VM install, git push or real Apply were performed. Actual Apply on Lucas's VM remains for Lucas to verify.
