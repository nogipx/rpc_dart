# rpc_dart_blob

Contract and adapters for streamed blob storage over `rpc_dart`. Think of it as the binary twin of `rpc_dart_data`: optimized for chunked uploads/downloads, checksums, and content types, without forcing base64 inside JSON payloads.

## Goals
- Separate contract for blobs (`BlobService`) so `rpc_dart_data` stays focused on JSON records.
- Stream-first API (client-stream upload, server-stream download) with optimistic versioning.
- Pluggable storage adapters (filesystem, SQLite for dev/tests, S3/minio later).
- Export/import-friendly framing (header + binary chunks) without loading whole files in memory.

## Layout
- `lib/src/models.dart` — descriptors, chunk frames, list/delete/head requests.
- `lib/src/adapters` — storage adapter interface for concrete backends.
- `lib/src/rpc` — contract, caller/responder wiring, service interface (client-stream upload, server-stream download; chunks are base64-framed for now).

## Status
Initial skeleton. Includes `SqliteBlobStorageAdapter` for local/dev storage (payloads kept in `BLOB` columns with optimistic versioning). Each collection gets its own SQLite table (registered in `blob_collections`) to isolate indexes and vacuum/backup scope. `BlobService` provides a default server implementation on top of any `IBlobStorageAdapter`. The API is intentionally small to evolve toward zero-copy binary framing (replace base64 chunks with transport-native binary when ready).
