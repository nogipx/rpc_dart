<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 2.0.0

Prepares the blob layer for a hosted S3, where a round trip is billed and a
bucket is a scarce resource. The interface changes are breaking.

**Breaking:**
- `IBlobRepository.collectionSize` returns `Future<int?>`. Null means the
  backend cannot answer without walking the whole store; 0 still means empty.
  The cost of this call ranges from an indexed query to a full enumeration
  depending on the backend, and a plain `int` hid that well enough for it to
  end up on a request path. Callers that need the number regardless sum
  `listBlobs` themselves, where the cost is visible.
- `CollectionSizeResponse.sizeBytes` is nullable to match.
- Three methods join `IBlobRepository`, so any implementation outside this
  repository must add them: `ensureCollection`, `deleteMany`, `headMany`.

**Batching:**
- `deleteMany` and `headMany` let a backend answer a batch the way it can —
  one statement on SQLite, `DeleteObjects` on S3, bounded parallel HEADs where
  there is no batch metadata call.
- `bulkDeleteBlob` and `bulkHeadBlob` were loops over single-blob calls in both
  the RPC responder and the in-process repository client; both now share
  `applyBulkDelete` / `applyBulkHead`. Fixing only the responder would have
  left the in-process path — the one a server holding a repository directly
  uses — still walking ids one round trip at a time.
- Version-checked deletes stay one at a time: that check is per id, while a
  batch delete is unconditional.

**Lifecycle:**
- `ensureCollection` makes setting a collection up an explicit act, so stores
  no longer have to re-discover its absence on every write.


## 1.2.2

**Web/dart2js correctness (verified on node):**
- `InMemoryBlobRepository` blob-id generation falls back from `Random.secure()` to `Random()` when secure randomness is unavailable in the runtime (e.g. node/dart2js without a proper `globalThis` crypto binding). Blob ids are not secrets, so this is a safe cross-platform compromise that no longer throws at startup on web.
- Added `test/web_smoke_test.dart` (runs on `vm || node`) exercising the full RPC client round-trip (put/get/list) and a mid-download `get` server-stream cancel; confirmed the client surface has no `dart:io` leak and the streaming `get` cancel does not deadlock on dart2js.

## 1.2.1

**Bug fix:**
- `BlobUploadChunk.toJson()` and `BlobDownloadFrame.toJson()` now coerce `bytes` via `Uint8List.fromList()` to guarantee correct CBOR byte string encoding on dart2js.
- `_bytesFromJsonValue` handles `List<dynamic>` (from CBOR array decoding) as a fallback for cross-platform compatibility.
- Bumped `rpc_dart` dependency to `^3.1.0`.

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
