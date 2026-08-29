<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 2.0.1

- The transaction helper no longer buries the error it was called to report.
  SQLite aborts the transaction itself for a whole class of failures
  (`SQLITE_FULL`, `SQLITE_IOERR`, `SQLITE_BUSY`), and the unconditional
  `ROLLBACK` in the error path then threw "cannot rollback - no transaction
  is active" over the top of the disk-full or IO error underneath — which is
  what reached the user instead of the cause. Rolled back only while a
  transaction is actually open, and the cleanup can no longer throw over the
  original. Same defect `rpc_data_sqlite` fixed in its own helper; this second
  copy was missed, and it sits on every blob write, delete and cache sweep.

## 2.0.0

- Implements `ensureCollection`, `deleteMany` and `headMany` from the
  `rpc_blob` 2.0.0 interface. Both batch operations run one statement per
  chunk, sized under SQLite's bound-variable ceiling, instead of one statement
  per id; `deleteMany` uses `RETURNING` so callers get per-id truth rather
  than a count they would have to guess against.
- `collectionSize` returns `Future<int?>`; this backend still answers a number.


## 1.0.1

- Web (dart2js / Wasm) path correctness. Verified the injected-`CommonDatabase`
  adapter surface (`SqliteBlobRepository.db`) imports only
  `package:sqlite3/common.dart` (Wasm-compatible); `dart:io`, `dart:ffi` and
  `package:sqlite3/sqlite3.dart` (FFI) stay confined to the
  `if (dart.library.io)` loader files and never leak onto the web import chain.
  The `.memory()`/`.file()` convenience factories go through the conditional
  loader whose web stub throws `UnsupportedError` (web apps inject their own
  `sqlite3mc`-on-Wasm db). The adapter's `async*` generators (`_chunkedPayload`,
  read/list streams) are `await`-first / yield-only over already-materialized
  bytes, so there is no `yield`-before-`await for` cancel-deadlock on dart2js.
  The `1 << 32` random-seed pattern exists only in the io-only loader (VM-only)
  and is not web-reachable. Added a JS compile smoke test
  (`test/web_smoke_test.dart`, `dart test -p node`) proving the web-facing API
  compiles to JS clean. Full Wasm db execution still requires the app to supply
  `sqlite3mc.wasm`.

## 1.0.5

- Allow to pass raw sqlite db connection to adapter

## 1.0.4

- S3 adapter now auto-detects public buckets and returns plain download URLs when anonymous `s3:GetObject` is allowed; presigning is used only for private buckets, still honoring `presign*` host overrides.

## 1.0.3

- Added presign-only endpoint overrides (`presignEndpoint`/`presignPort`/`presignUseSSL`/`presignPathStyle`) for S3/MinIO to sign links on a public host behind a reverse proxy; removed `downloadUrlMapper` to avoid generating invalid signatures.

## 1.0.2

- S3 adapter can rewrite presigned download URLs via `S3BlobStorageOptions.downloadUrlMapper` (useful for serving through a proxy/CDN) and configure presign TTL via `S3BlobStorageOptions.presignTtlSeconds`; constructor params consolidated into `S3BlobStorageOptions`.

## 1.0.1

- S3 adapter now fetches object tags (`?tagging`) and merges them into `BlobDescriptor.metadata` without overwriting metadata provided on upload.
- Added `xml` dependency to parse S3 tag responses.

## 1.0.0

- Added `S3BlobStorageAdapter` (S3/MinIO/Ceph-compatible) storing blobs under `<prefix><collection>/<id>` with metadata-based versioning and optimistic checks.
- New `S3BlobStorageAdapter.connect(...)` helper for quick setup; list/Head/read/write/delete/listCollections wired to S3 operations; descriptors include a presigned download URL.
- README now documents S3/MinIO usage; pubspec updated with the MinIO client dependency.
- Initial version.
