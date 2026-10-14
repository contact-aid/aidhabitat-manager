# Incoming scanned documents

The outgoing document upload and incoming document list refresh are separate paths. A green document status confirms the upload; it does not mean that another device has refreshed its local list. DocumentsScreen previously refreshed remote metadata on entry and foreground only. Sync notifications reloaded SQLite without requesting incoming files, so a screen left open could miss documents uploaded elsewhere indefinitely.

Build 85 reads the remote list every 15 seconds while DocumentsScreen is active and online. Reads do not overlap, pause in the background and stop on disposal. Existing previews and local edit queues continue to use the repository's revision and pending-operation protections. Failed reads retain the last local snapshot and retry. Each list GET bypasses browser caches and rejects incomplete success envelopes and document identities before reconciliation.

Read-only production investigation confirmed four existing scanned PDFs were stored, parseable, and associated with the expected beneficiary. No document contents were changed, reuploaded or deleted. Physical device confirmation remains required; this Mac has no authenticated browser session for the affected user.

Validation: critical Flutter suite, incoming-list transport tests, polling lifecycle/error tests, analyzer, publication manifest checks. No patient identifiers or document contents are included in this report or test fixtures.
