# First accessibility synchronization: unanswered versus No

The iPad stores a nullable street-access answer in two SQLite columns:
`easy_access` (0/1, non-null) and `easy_access_set` (presence). The old outgoing
mapper discarded the presence marker and mapped an unanswered baseline to false.
A first Yes then conflicted with a null server answer, blocking the complete
housing patch. A first No could change only the marker and enqueue no request.

Build 108 keeps the pair together in both the changed values and their captured
baseline, sending null, false or true through the existing `easyAccess` API field.
Equipment-only edits do not submit an unrelated access answer.

Server compatibility repairs the old false baseline only if the fresh server
record is still null AND its timestamp exactly matches the original queued
reference. It recomputes that comparison after a competing conditional write;
it neither changes the stored value to false nor turns null/false into globally
equivalent values. A later web edit/clear remains a conflict. Housing writes still
use their original write ID, revision checks and write journal.

At sync startup, build 108 retries a matching legacy housing-visit conflict once,
only for the original owner and an unchanged observed server version. Its original
payload is retained in encrypted conflict history. The submitted fields, baseline
and write ID remain untouched. Ambiguous references, additional conflicting
fields, explicit remote answers and newer server versions require review.

Validation: five new regression cases failed before the mapping correction.
The focused Flutter suite covers first Yes/No, No-only changes, clearing a No,
multiple offline edits, equipment-only updates, recovery, ownership and genuine
web conflicts. The server tests cover the complete levels/equipment/exterior
patch and a web edit racing the conditional write. No live patient data is
rewritten by a migration or forced replay.

Integrated with PR #99's general preference for entered values over defaults.
For the street-access field specifically, promotion from an unknown/incorrect
reference is allowed only when its original source version is still current.
A correct null baseline continues to merge through the normal three-way path,
even when an unrelated server field has changed. The automatic client resolver
also retains ambiguous legacy false references after a newer server version.
Post-integration validation: 563 server tests and 114 focused Flutter tests pass,
with targeted analysis clean.
