<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 2.0.0

**Breaking — one bucket, a prefix per collection:**
- Objects live at `<collection>/<id>` in the single bucket named by
  `S3BlobStorageOptions.bucket`; `bucketPrefix` is gone. A bucket per
  collection does not survive a hosted S3, where accounts are capped on bucket
  count and creating one is heavyweight. Existing data must be copied under
  its prefixes before this version reads it.
- `collectionSize` returns null: S3 cannot size a prefix, and the MinIO admin
  API that used to answer this reports per bucket, which no longer corresponds
  to anything. `useAdminApi` is gone with it, along with the SigV4 signing it
  needed and the `http.Client` it leaked per call — the adapter now needs
  plain S3 permissions rather than admin ones.
- `deleteCollection` walks the prefix and deletes in batches instead of
  dropping a bucket; `listCollections` reads common prefixes.

**Requests per operation:**
- A write was six round trips (`bucketExists`, then `headBlob` which is itself
  `statObject` + `getObjectTags` + `getBucketPolicy`, then `putObject`, then
  `getBucketPolicy` again for the URL). It is one. `ensureCollection` replaces
  the per-write bucket check, a missing bucket is repaired from the error
  instead of polled for, `immutableObjects` skips the read-before-write for
  content-addressed stores, and `publicRead` states what the bucket is instead
  of asking it per descriptor.
- `listBlobs` built each descriptor with a HEAD, making a page of N cost N+1
  requests. It reads size and mtime from the listing; `includeMetadata` — which
  already existed and promised exactly this — opts back into the HEADs.
- `fetchObjectTags` (default off) stops paying a `GET ?tagging` per head for
  tags this adapter never writes.

**Hosted S3 readiness:**
- Throttling and transient faults are retried with exponential backoff and
  jitter (`maxRetries`, `retryBaseDelay`), and `requestTimeout` bounds a call
  that never answers. Listings are deliberately not retried: their paging
  state lives in the client, so a restart would replay rather than resume.
- `connect` takes `region`, so a hosted bucket does not need a lookup on first
  use.
- `writeBlob` documents that it buffers the object in memory — the checksum is
  verified over what is stored and a retry has to be able to resend it, which
  caps object size at `memory / concurrent writes` until multipart exists.


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
