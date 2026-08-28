<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 1.0.2

- `transaction()` now awaits its body. It never did: every caller passes an
  async closure, so `COMMIT` ran at the body's first `await` and the writes
  landed afterwards, outside the transaction. Nothing this adapter did was ever
  atomic, and a body that failed part-way left its earlier writes committed.
- `ROLLBACK` is only issued when a transaction is actually open. SQLite aborts
  the transaction itself for a whole class of errors (`SQLITE_FULL`,
  `SQLITE_IOERR`, `SQLITE_BUSY`...), and the unconditional rollback then threw
  `cannot rollback - no transaction is active` straight over the top of the real
  failure — so the disk-full or IO error the caller needed to see was replaced by
  a meaningless SQL logic error. It could also tear down a transaction opened by
  someone else in the meantime.
- Transactions are serialized per connection. Now that a body is awaited, a
  transaction spans its awaits, and a connection has exactly one transaction with
  no nesting — overlapping callers queue instead of colliding on `BEGIN`.

Note on the shape: sqlite3 is synchronous throughout, so the futures in
`SqliteDataDatabase` are a leftover from the Drift-shaped shim it used to be, and
a synchronous executor would give atomicity by construction and make the queue
above unnecessary. That conversion was tried and decided against — it surfaces a
latent nested transaction (`upsertSchema` -> `getActiveSchema` -> `ensureReady`,
which opens its own) that needs a design change rather than a mechanical
rewrite. The async surface is settled, not pending.

## 1.0.1

- Web (dart2js / Wasm) path correctness. Verified the injected-`CommonDatabase`
  adapter surface (`SqliteDataStorageAdapter.connection`) imports only
  `package:sqlite3/common.dart` (Wasm-compatible) and `package:sqlite3/wasm.dart`
  on the web path; `dart:io`, `dart:ffi` and `package:sqlite3/sqlite3.dart` (FFI)
  remain confined to the `if (dart.library.io)` loader/connection files and never
  leak onto the web import chain. The `.memory()`/`.file()` convenience factories
  go through the conditional loader whose web stub throws `UnsupportedError`
  (web apps inject their own `sqlite3mc`-on-Wasm db). Added a JS compile smoke
  test (`test/web_smoke_test.dart`, `dart test -p node`) proving the web-facing
  API compiles to JS clean. Full Wasm db execution still requires the app to
  supply `sqlite3mc.wasm`.

## 4.0.0

- Initial extraction from `rpc_data` with SQLite/SQLCipher adapter, schema registry, connection helpers for IO and WebAssembly.
