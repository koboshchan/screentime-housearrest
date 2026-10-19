# Native baseline and category preservation

Apply requires an existing matching native Daily and enclosing Weekly baseline. It never creates Daily or Weekly from sparse Hourly observations. Missing history is unknown, not zero. Weekly per-app values retain their native outside-selected-day contribution and only replace the selected-day contribution.

Existing category aggregate values are left untouched, including unequal values and web data. Category and app fields other than application duration stay intact. Segment totals are app sums including overlap. Categories may therefore be stale, by explicit user choice. Newly required hourly categories start at zero rather than borrowing another interval's aggregate.

Future refresh metadata is the normal Gemini bypass, not proof of unsafe provenance. A verified Surface archive explicitly recording the baseline as absent, combined with exact reconstruction of the old identity-stripped synthesized output, rejects a known legacy synthetic baseline. Native regeneration is not blanket rejected just because an older absence archive exists. No device Apply or restore is part of release verification.

The production planner has no HOST_STORAGE_TEST safety bypass. The host fixture constructor only supplies disposable filesystem paths; it invokes the identical planner and guards. Tests exercise valid unequal native categories, byte-equal aggregate and unrelated fields, weekly outside-day deltas, missing baselines before writes, longer future timestamps, and verified legacy-synthesis provenance.
