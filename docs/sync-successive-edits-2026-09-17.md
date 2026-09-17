# Successive-edit synchronization fix

## Confirmed failure

The regression test `birth date then invalidity sync without self conflict
(overlap=true)` fails against commit 2aec08c with one conflict, and passes with
this correction. It uses synthetic data and the strict timestamp guard used by
the current API (the conditional-sync environment flag was not configured).

1. Mutation A starts sending a birth-date change at server version V0.
2. Another edit replaces the queue row with a coalesced mutation B, still at V0.
3. A succeeds on the server at V1. The old payload-ownership check discards V1
   because B has replaced A locally.
4. B is sent at V0 and the server rejects it as stale.

The screenshots alone do not establish that this was the exact sequence of the
reported incident. The old client did not record enough detail to attribute it.
This bug predates the AGGIR feature; deploying AGGIR did not rewrite patient data.

## Correction and boundaries

- Patient, housing and dossier updates acknowledge their payload and store the
  returned server version in one SQLite transaction.
- Coalesced mutations retain a bounded list of predecessor write IDs. Only a
  pending, proven successor of an acknowledged write can advance its reference.
  Its original reference and affected baseline fields must also match.
- Preserve the latest desired values, including entire occupant arrays. Rebase
  only baseline values actually written by the acknowledged predecessor.
- Do not acknowledge the successor as completed. It remains pending for another
  synchronization cycle.
- Never advance a conflicted, unrelated, unknown-baseline or already-rebased
  mutation from an old acknowledgement. Do not merge arrays by position.
- The conflict screen distinguishes a changed local form baseline, a newer
  server reference, a field conflict and an unavailable reference. Where
  available, it shows both version timestamps without guessing the author.

No authentication reset, cache purge, pending-edit deletion or conditional-sync
server activation is part of this fix. Lost network acknowledgements and genuine
concurrent remote edits are not automatically resolved by this mechanism.

## Validation

- The regression fails on the preceding implementation and passes after the fix.
- Critical synchronization suite: 652 tests passed.
- Targeted Flutter analyzer: no issues.
- Tests cover sequential and overlapping patient edits, preserved newer dossier
  edits, rejected unrelated rebases, atomic rollback and conflict-screen layouts.

Web deployment must be verified using release.json and the main.dart.js hash.
Already installed native builds require a new TestFlight/App Store build.
