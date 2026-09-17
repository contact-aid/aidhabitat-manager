# Context and atomic synchronization

This change follows recovery commit 52d1a0c. It is a coordinated client/API
protocol change, NOT an activated production migration.

## Three corrections

1. Context/autonomy use GET/PUT `/api/contextes/:dossierId` and their own
   `{recordId, revision, updatedAt?}` reference. Updating a dossier no longer
   invalidates the context's reference. The old context PATCH is rejected with
   428 when conditional synchronization is enabled, before any partial write.
2. SQLite v25 preserves existing data and pending operations while adding an
   explicit known/unknown context reference. Acknowledgement stores the own
   reference and completes the exact mutation atomically. A proven successor
   advances from that acknowledgement only; remote refresh never rebases an
   unconfirmed local edit. Old queued context edits with no captured reference
   require explicit comparison, not a guessed baseline or discarded queue.
3. The conditional writer now covers all seven business tables: beneficiary,
   housing, dossier, context, measurements, observations and sanitary details.
   Reads/planning are followed by a database conditional update on Id AND
   app_sync_revision. A failed condition never falls back to a legacy PATCH.
   Divergent edits are preserved as conflicts; uncertain confirmation stays
   retryable with the same writeId. Generic unguarded updates remain blocked.

Secondary creation is explicitly create-only and gated separately. The stable
writeId is retained as the creation revision (including through createRecord),
so a lost response can be recognized without creating a second row. Creation
requires a DATABASE uniqueness constraint on dossier_id, not just an API read.

## Validation

- 694 critical Flutter tests passed, including context own-reference capture,
  pending-edit preservation, v24-to-v25 migration, revision-only ACK, successor
  rebase and explicit create-only guards.
- 214 server tests passed. Real Express secondary routes are exercised against
  synthetic REST fixtures with conditional synchronization on and creation
  both disabled/enabled. Simultaneous conflicting edits cannot both commit;
  replay does not write twice. Context route tests exercise independent parent
  changes, competing writes, duplicate rows, authorization and creation gates.
- Six read-only readiness-tool tests pass, covering seven tables, missing
  revisions, duplicate dossier ownership and pagination without exposing data.
- Flutter analysis: no issues.
- iOS release build without codesigning succeeded (42.4 seconds, 38.3 MB).
- No real beneficiary data was changed. These tests do not substitute for a
  staging database probe or two physical iPads with intermittent connectivity.

## Required rollout order

Do not deploy the new client alone: its context endpoint deliberately returns
503 until the server is prepared. Do not enable conditional synchronization on
an unprepared database or while incompatible clients are still writing.

1. Inventory and preserve pending queues on each installed client. Never force
   logout, clear storage, reinstall or reload to discard unsent work.
2. Back up and prepare all seven tables in staging: valid app_sync_revision on
   every row, supported writable scalar columns, and unique dossier_id indexes
   for each of the four child tables. Resolve duplicates explicitly. A clean
   scan does not prove the presence of an index.
3. Run `tools/check-conditional-sync-readiness.mjs --base=pskgbjythubfzv9 --check`
   with the staging/read-only connection. It never writes or approves activation.
   Verify actual conditional-write behavior using the isolated probe tools.
4. Audit other writers/importers: protected generic updates fail closed. All
   active writers must participate in revision updates. Coordinate old-client
   cutover; old context PATCH receives 428, not an unconditional write.
5. Deploy the API and compatible web/native clients together in staging. Enable
   AIDHABITAT_CONDITIONAL_SYNC=1 only after preparation. Set
   AIDHABITAT_UNIQUE_CHILDREN_READY=1 only after verifying the database indexes.
6. Test two iPads: independent dossier/context edits, same-section competing
   edits, child creation from both devices, offline edits, response loss during
   a second edit, and explicit resolution of legacy pending conflicts.
7. Activate in production only after that recipe passes. Keep old recovery
   commit 52d1a0c separately identifiable. Do not revert to unguarded writes
   while the new protocol is active; pause writes and preserve queues instead.

No deployment, schema change, flag activation or App Store upload was performed
as part of this code change. Legacy paths remain non-atomic with the gate off.
