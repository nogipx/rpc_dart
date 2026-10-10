---
status: awaiting owner
round: 771
commit: c40f00a7
paths: [packages/data/rpc_data/lib/src/change_journal.dart, packages/data/rpc_data/lib/src/repository/base_data_repository.dart, packages/data/rpc_data_sqlite/lib/src/repository/sqlite_data_repository.dart]
probe: packages/data/rpc_data/.dart_tool/probe/r772_journal_by_count.dart
reason: owner — decided to remove the journal; out of the current focus (rpc_dart and transports only)
rank: 11
---

# B-272 — the data change journal is bounded in events, not bytes

`InMemoryDataChangeJournal`, the default journal of `BaseDataRepository`
(so of `InMemoryDataRepository` and `SqliteDataRepository`; Postgres has
its own), keeps the last `journalMaxEvents` (5000) events per collection,
each with the full record. Measured: one record of 256 KiB rewritten 2000
times holds +595 MiB, against +4 MiB for 100 B, while the store keeps one
version. Collections are not counted, so the total has no bound. RPC-27's
shape.

## Owner decision

2026-10-09: the journal can be removed altogether. Not now: the loop
works on rpc_dart and the transports only until told otherwise.
