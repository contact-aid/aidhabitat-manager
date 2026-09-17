# Synchronization recovery follow-up

Scope: patient, housing and dossier PATCH; measurements, observations and
sanitary-details PUT. This follows the successive-edit fix in 0fac454.

## Corrections

- Child acknowledgements now store the native version and complete the exact
  mutation in one SQLite transaction. A newer edit stays pending and advances
  only from a proven predecessor acknowledgement.
- Coalescing an in-flight or previously attempted versioned mutation preserves
  its exact payload as `retryMutation` inside the encrypted queue. After an
  uncertain response, confirm that predecessor first, then advance the newer
  edit. Conflict review clears this recovery state after an explicit decision.
- Legacy server routes may acknowledge a retry without writing only when all
  supplied, mapped values match the authorized remote record. This confirms
  content, not who wrote it. A differing remote value is never overwritten
  through a stale timestamp. Known changed baselines are checked even when a
  recovered acknowledgement advanced the timestamp.
- Patient, housing and dossier clients retain incomplete/invalid acknowledgements
  as transient failures. The server no longer returns successful null versions
  for existing rows. Patient ACKs read native row metadata instead of the DTO,
  whose fallback clock could previously invent a version.

## Tests

- Six child acknowledgement ordering cases, including the former split-transaction
  window; original stale-response and conflict protections retained.
- Lost response and missing-version response while a newer patient edit is queued:
  predecessor is confirmed first, newer edit is then synchronized.
- Eighteen primary API acknowledgement transport cases.
- Real Express routes against isolated synthetic NocoDB fixtures: replay causes
  no second write, a competitor remains protected, missing version returns 503
  then a successful retry. Secondary routes exercise the same replay protection.
- Full server suite and critical Flutter synchronization suite.

Validation on 2026-09-17: 678 critical Flutter tests passed; 204 server tests
passed; Flutter static analysis reported no issues. One UI ownership test failed
under concurrent test/build load on an earlier run, passed alone, and passed in
the subsequent complete critical run. The initial two ACK fixture failures were
updated to return the now-required native version, not an empty success body.

## Release Boundaries

Both API and client changes are required. Ship API first, then web/native clients.
Do not discard offline queues or force logout/reload with unsent work. Existing
conflicts still need their explicit review; they are not silently resolved.

No production data or schema migration is required by this patch. This does not
enable AIDHABITAT_CONDITIONAL_SYNC, nor claim atomic multi-device compare-and-write
for the legacy NocoDB API. The separate context-of-life multi-table protocol and
pre-existing unversioned legacy mutations are outside this versioned recovery
change. A true concurrent edit, unknown baseline or missing record still requires
review rather than an automatic overwrite.
