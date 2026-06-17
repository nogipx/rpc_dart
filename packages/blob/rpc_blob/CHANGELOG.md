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
