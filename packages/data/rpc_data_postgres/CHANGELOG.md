<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 2.0.0

**Breaking — cursors issued by 1.x are rejected by this version.** They are
short-lived, so the practical cost is one restarted page walk.

- Pagination cursors are self-contained tokens carrying the boundary
  (sort value + id) instead of the boundary record's id. The old cursor was
  re-read on the next page, which made paging depend on that row surviving
  unchanged: deleting it failed the next page with `invalidArgument`, and
  updating it moved the boundary so rows in between were silently skipped or
  repeated. Both are covered by tests now.
- The keyset tiebreaker is `id` rather than `ctid`. Postgres rewrites `ctid` on
  every UPDATE and on `VACUUM FULL`, so it could never anchor an order.
- Two queries per page are gone with the re-read (`_cursorExists` and the
  boundary lookup); full-text search paged the same way and got the same fix.
- `writeRecords` no longer compares against versions read *before* the upsert.
  A concurrent writer landing in between made a refused row look like it
  applied, so the batch reported success for a write it had dropped. The
  upsert now reports which ids landed (`RETURNING id`) and only the refused
  ones are re-read.
- Documented what the adapter does not push down: `RecordFilter.containsTerms`
  compiles to `LOWER(payload::text) LIKE '%term%'`, a full scan no index
  serves. The class comment previously claimed the opposite — that queries were
  materialised in Dart — which had not been true for some time.
- Tests take the connection URL from `RPC_PG_URL`, so they can run against a
  throwaway instance instead of whatever holds the default port.


## 4.0.0

- Initial extraction from `rpc_data` with PostgreSQL JSONB adapter and repository.
