# Large note content: isolated candidate, not deployed

The server's inline GZIP/base64 encoding can exceed NocoDB's 100,000-character LongText limit even when the HTTP request is below 30 MiB. This change keeps the existing inline format when it fits and stores larger drawing/text values as immutable fragments in the existing mobile_document_chunks table. No schema migration is needed.

## Protocol and preservation

- Each fragment contains at most 90,000 base64 characters. `document_uuid_source` has a reserved `note-content-v1:` prefix and hashes of the note identity/field and decoded content. There is no mobile_documents row for these objects and no patient metadata on fragments.
- A `NOTE_CHUNKS_V1:` manifest in drawing_json/text_content records owner, decoded byte count and SHA-256, encoded length/SHA-256, and fragment count. The owner binds patient, scope, tab, subtab, page and field.
- Prepare encodings without writes. Reject a stale/missing revision first. Stage immutable fragments, read every fragment back, verify counts/lengths/hashes and decompress. Only then publish the manifest with the existing conditional note revision update. Never clear expectedRevision or choose a version automatically.
- Retry can reuse exact fragments. A lost fragment ACK is confirmed by reading that fragment. Identical duplicate fragments are accepted (concurrent identical writes); different duplicates, missing/out-of-range/foreign fragments, invalid manifests and hash mismatches fail closed. Nothing is silently returned as an empty note.
- A lost final note ACK can be retried with the same writeId. A concurrent revision change prevents publication. Unreferenced staged versions remain retained. No garbage collection is introduced.
- The existing single-process creation lock is retained. This is not a new distributed uniqueness guarantee: deployment remains a single API instance.

## Reading and access

API list/direct reads reconstruct original strings, so clients 64/70/71 continue using the same payload. PDF and independent-note consumers receive resolved drawingJson/textContent through the same store. Existing independent-note initialization markers remain unchanged; raw Plans/Résumé content is preserved byte for byte.

PUT/DELETE/preview routes perform metadata-only identity lookup before authorization and any fragment loading. A preview rechecks the patient after the authorized full read. Document read/delete helpers reject the reserved namespace. Document listings exclude it; upload cleanup only targets `upload_` keys. Maintenance scripts reading NocoDB directly must understand manifests before interpreting note contents.

## Bounds

20 MiB is the combined decoded UTF-8 budget for text plus drawing on one note, not 20 MiB per field. Decompression enforces this bound for both old GZIP values and new fragments. A list request has a cumulative 64 MiB decoded-content budget and is read serially; overflow fails the entire read.

The existing HTTP JSON limit remains 30 MiB for the entire serialized request, including escaped drawing JSON, text, preview and metadata. Thus some strings can hit the HTTP limit before the decoded-content limit. These are bounded limits, not an unlimited upload promise. Large fragment writes are sequential and can require retries under a real proxy deadline; production latency has not been tested.

## Delivery prerequisites and rollback

Independent review, exact candidate tests, backup of server notes AND document fragments, and deployment authorization are required. This code does not resolve the two incident operations or any version choice.

The incident uses API-only backup; a wired iPad backup is not a prerequisite. Build 70 cannot explicitly export its queued note and a conflict is not resent by global retry. Therefore an API-only backup of the blocked plan cannot be guaranteed before installing a client with explicit export support. Server backups do not contain unsent iPad edits. Coordinate that client dependency and verify each real backup receipt plus exact content readback before treating a local note as protected. Do not resolve a conflict merely to trigger capture.

## Prepared API fallback

Branch `codex/appergo-api-reader-fallback` starts at production 71 (`b7d054d6288b40d1f9af3df328357f4ce8a839de`) and adds only the note chunk implementation plus this documentation. It deliberately has no note-backup API endpoints or passive capture hook. This is an API code fallback, not a downgrade of the iPad or web client. Main owns image construction, publication and service configuration.

When reverting the backup API, keep its encrypted volume and all key versions intact; endpoint removal does not erase the archives. Retain the independent backup verifier from the backup release in a secure recovery toolkit. Client backup requests will no longer be supported on this fallback, so never present them as successful. This branch keeps both reading and writing of NOTE_CHUNKS_V1, including the conditional-write protections. It does not flatten or migrate manifests back to inline text.

After the first manifest is written, rolling the server back to a version without this reader is unsafe: that server cannot reconstruct the content. Keep a compatible reader in any rollback build. Old clients remain compatible through the upgraded API; direct NocoDB readers and external automation have not been inventoried beyond this repository.

No schema/data migration, service change, real note write, iPad installation or deployment was performed during preparation.
