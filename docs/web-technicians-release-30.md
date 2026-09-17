# Compatible web release 30

Includes AGGIR, successive-edit and lost-ack recovery, technician profiles and
report template, recommendations selected initially, and five web columns.
The conditional context protocol from 58f76e2 is deliberately excluded.
No database migration or conditional-sync feature flag is enabled.

Deploy API first and verify readiness, then web. Keep existing IndexedDB data,
offline queues and native clients. Do not force logout or clear local storage.
The native application is not uploaded or changed by this web release.

The ownership-screen test now waits for SQLite-backed loading to finish instead
of assuming it takes less than 100 ms. Its deliberately pending opener still
remains pending until the test releases it.
