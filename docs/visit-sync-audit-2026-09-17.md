# Visit report synchronization audit - 2026-09-17

Scope: release worktree, legacy production protocol. Conditional synchronization
flags remain disabled. This audit is not a production certification or a claim
that every widget has been exercised in a browser.

## Verified and corrected locally

- Beneficiary reference writes used foreign-key columns absent from the read
  projection. Added family situation, occupation, dependency, income category
  and both pension-fund foreign keys. HTTP tests cover first selection, replay
  without a second write, and a competing selection for family situation,
  occupation and both pension funds.
- Housing reference foreign keys were also absent from the projection. Added
  housing type, garage-door and gate keys.
- Thirty housing/accessibility/heating checkboxes read empty database values
  as false, but compared them against the string "false" as different values.
  A column-specific comparator now matches those representations. Tests retain
  conflicts for a changed value and an absent projection column.
- Street accessibility is nullable. Its writer now preserves null rather than
  silently turning it into false. It is excluded from default-false comparison.
- An AST-based regression check covers mapped database columns for beneficiary,
  dossier, housing, context, bathroom/WC, measurements and observations. Nested
  JSON properties are not database columns and are not certified by this check.

## Remaining findings (not fixed by the changes above)

1. Context/medical/autonomy writes still use the dossier timestamp while saving
   a different row. Dossier updates can cause false context conflicts; context
   writes need their own version to prevent overwrites. The separately tested
   context CAS module is not connected to the legacy production route.
2. Legacy check-then-write routes are not atomic. Two requests can pass the
   timestamp check before either writes. Passing sequential tests does not
   establish simultaneous-device safety.
3. Bathroom/WC GET reconstructs room arrays from legacy scalar fields when
   room JSON is empty. Recovery compares the submitted array baseline with
   raw stored JSON. This is the same class of representation mismatch as the
   previously corrected beneficiary birth-date issue. Existing secondary HTTP
   tests cover writes and timestamps but do not validate this legacy fallback.
4. Beneficiary nonempty JSON can omit optional defaults that GET adds. Housing
   empty room breakdowns also need round-trip baseline coverage. Neither is
   covered by the scalar checkbox fix.
5. Notes/drawings, plan replacement, and the selected recommendation list use
   separate upsert/replacement paths without the same version/baseline guard.
   They require dedicated simultaneous-write and lost-response tests. Lack of
   a visible conflict is not evidence that overwrites cannot occur.
6. Unknown nonempty reference labels are currently ignored by mappers. This
   avoids clearing existing data, but is not an explicit failed-save response.

## Evidence

- `npm run test:server`: 246 passed, 0 failed.
- `node tools/check-sync-contracts.mjs`: 11 autonomy contract elements passed.
- Secondary route suite: 51 HTTP scenarios across measurements, observations
  and bathroom/WC (authorization, partial writes, versions, clear, readback).
- No production deployment, cache reset, queued-operation removal, or patient
  data write was performed during this audit.

Next release gate: reproduce and cover findings 1-5 with actual client baselines,
including two simultaneous writers, before describing the complete visit report
as synchronization-safe. Preserve the pending user edits during recovery.
