# Document rotation: imported identity follow-up

## Scope and status

Local changes only, worktree `/private/tmp/appergo-preconisations-description`, branch `codex/fix-preconisations-description`, base `d3ff3f8`.
No patient data accessed, no deployment, no build distributed, no production validation.
The reported iPad build is 23. The precise GAUDIN incident is not reproduced on device.

## Static diagnosis

Imported documents receive a local `remote_doc_...` identifier distinct from the server's `clientDocumentId`. Previously the upload used that local identifier. The server replacement lookup in `mobileSyncStore.mjs` uses patient plus client document identifier, so this path can create a second document instead of replacing the imported original. A changed remote content UUID also prevents matching an imported row by its old content URL alone.

This is distinct from the deletion fixes reported by the other agent. It does not prove which mechanism occurred in the actual reported incident.

## Correction

- Persist the canonical server identity in existing SQLite `kv_store`, scoped by patient and local document ID.
- Preserve the local ID and queue ownership, but send the canonical identity for replacement uploads.
- Match imported documents by this identity when remote content UUIDs change, keeping existing retired-content rejection effective.
- For previously imported documents without a marker, recover identity using the existing document-list API and an exact, unique nonempty path match. Persist it before uploading for retries.
- Missing or ambiguous identity raises an error instead of silently creating a new remote document. Local content is not deleted. Recovery/retry UX for this exceptional case is not separately validated.
- No server contract or schema migration.

## Files for document fix

- `aid_habitat_app/lib/services/document_upload_identity.dart` (new)
- `aid_habitat_app/lib/services/document_repository.dart` (import and merge identity hunks)
- `aid_habitat_app/lib/services/nocodb_sync_service.dart` (import and upload identity hunks)
- `aid_habitat_app/test/services/document_remote_revision_test.dart` (import and three added tests)
- `aid_habitat_app/test/services/document_imported_upload_test.dart` (new)

The same worktree also contains separate recommendation-description/drag-overlay changes in `recommendations_tab.dart` and `recommendations_gestures_test.dart`. Do not confuse them with the document patch.

## Verification

Synthetic Flutter regression suite: 89 tests passed across document_remote_revision, document_revision_save, document_imported_upload, document_relocation_upload, document_upload_confirmation, document_preview_revision and recommendations_gestures.

After excluding empty URI paths from identity resolution, the remote revision and imported upload suites were rerun: 34 tests passed. They cover identity retention across repository recreation, changed remote UUID, stale imported content after upload acknowledgment, absent/ambiguous identity, cross-patient separation, and multipart uploads with the original canonical identifier and changed bytes. HTTP is mocked; SQLite is in memory. These are not end-to-end NocoDB tests.

Native PDFKit fixture test compiled with `xcrun swiftc ios/Runner/PdfInkEditor.swift tool/pdf_ink_native_test.swift` and passed on macOS: rotation and annotations persisted with original PDF text. This is not iPad validation.

## Integration and limits

The other agent modified document deletion and stale-list protection in shared document repository/sync files. Integrate these identity hunks alongside those changes, not by replacing entire files. Preserve that agent's regression tests and rerun the combined suite. This isolated branch does not contain their latest deletion fixes.

A new iPad build is required after integration; build 23 does not receive these local changes automatically. Device acceptance: rotate an imported synthetic multipage report, save, leave/reopen, restart, reconnect, and verify one server record, correct orientation in viewer and thumbnail. Repeat deletion after rotation with the other agent's patch.

No deduplication of already-existing remote duplicates is attempted. Legacy imports whose old URL is no longer present may need explicit reconciliation before upload. No claim of complete absence of regressions or operational production protection.
