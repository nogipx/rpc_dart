<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_blob

Core contract and RPC wiring for streamed blob storage over `rpc_dart`. Think of it as the binary twin of `rpc_data`: optimized for chunked uploads/downloads, checksums, and content types, without forcing base64 inside JSON payloads. Storage adapters now live in sibling packages (`rpc_blob_sqlite`, `rpc_blob_minio`).

## Quick start

### Server
```dart
final storage = /* e.g. SqliteBlobStorageAdapter.file(...) from rpc_blob_sqlite */;
final server = BlobServiceFactory.createServer(
  transport: transport, // any IRpcTransport
  storage: storage,
  maxChunkBytes: 256 * 1024, // reject larger uploads
);
await server.start();
```

### Client
```dart
final client = BlobServiceFactory.createClient(
  transport: transport,
  uploadChunkBytes: 256 * 1024,
);

// Upload stream (chunked automatically).
await client.putBytes(
  collection: 'photos',
  id: 'p1', // optional; generated if absent
  bytes: file.openRead(),
  length: await file.length(),
  contentType: 'image/jpeg',
  checksum: '<sha256-of-file>',
  checksumAlgorithm: ChecksumAlgorithm.sha256,
  attachChunkChecksums: true, // optional per-chunk validation
);

// Range download with offsets reported on first frame.
final frames = await client.get('photos', 'p1', rangeStart: 0, rangeEnd: 1024).toList();

// Metadata only.
final head = await client.head('photos', 'p1');

// List without metadata (faster); set includeMetadata: true to fetch it.
final list = await client.list('photos', limit: 10, includeMetadata: false);

// Delete with optimistic version (optional).
await client.delete('photos', 'p1', expectedVersion: head.descriptor?.version);
```

### In-memory setup (tests/dev)
```dart
// Using BlobServiceFactory helper
final env = await BlobServiceFactory.inMemory(
  uploadChunkBytes: 128 * 1024,
  maxChunkBytes: 256 * 1024,
);
final client = env.client;

// Or using InMemoryBlobRepository directly
final storage = InMemoryBlobRepository(
  maxBlobBytes: 10 * 1024 * 1024, // 10MB limit
  readChunkBytes: 256 * 1024,
);
final server = BlobServiceFactory.createServer(
  transport: transport,
  storage: storage,
);
```

### S3/MinIO adapter
```dart
final storage = S3BlobStorageAdapter.connect(
  bucket: 'blobs',
  endPoint: 'minio.local', // or s3.amazonaws.com
  port: 9000,
  accessKey: '<access>',
  secretKey: '<secret>',
  useSSL: false,
  options: const S3BlobStorageOptions(
    prefix: 'rpc/', // optional
    presignTtlSeconds: 3600, // optional, default 3600
    // If MinIO/S3 sits behind a reverse proxy and public host differs, presign directly on it:
    presignEndpoint: 'files.example.com',
    presignPort: 443,
    presignUseSSL: true,
    presignPathStyle: true, // optional; keep false if virtual-host style works
    presignRegion: 'us-east-1', // required to avoid region lookup during presign
  ),
);
final server = BlobServiceFactory.createServer(
  transport: transport,
  storage: storage,
);
```
Descriptors returned from S3 include a download URL (`downloadUrl`). The adapter now auto-detects public access: if bucket policy allows anonymous `s3:GetObject`, it returns a plain URL; otherwise it presigns. Prefer `presignEndpoint`/`presignPort`/`presignUseSSL`/`presignPathStyle` when the public host differs from the internal one — the URL (presigned or plain) will use those host overrides. Set `presignRegion` explicitly to avoid any region lookup when generating presigns. `S3BlobStorageOptions` also configures prefix/clock and `presignTtlSeconds` (link lifetime).

## Goals
- Separate contract for blobs (`BlobService`) so `rpc_data` stays focused on JSON records.
- Stream-first API (client-stream upload, server-stream download) with optimistic versioning.
- Pluggable storage adapters (SQLite for dev/tests, S3/MinIO for object storage; bucket must exist).
- Export/import-friendly framing (header + binary chunks) without loading whole files in memory.

## Layout
- `lib/src/models.dart` — descriptors, chunk frames, list/delete/head requests.
- `lib/src/adapters` — storage adapter interface for concrete backends.
- `lib/src/rpc` — contract, caller/responder wiring, service interface (client-stream upload, server-stream download; chunks are base64-framed for now).

## Status
Includes three storage adapter implementations:
- `InMemoryBlobRepository` — pure in-memory storage for testing and development (no persistence)
- `SqliteBlobStorageAdapter` — local/dev storage (payloads kept in `BLOB` columns with optimistic versioning)
- `S3BlobStorageAdapter` — S3-compatible backends (AWS, MinIO, Ceph) storing blobs as `<prefix><collection>/<id>` with metadata-based versioning

`BlobService` provides a default server implementation on top of any `IBlobStorageAdapter`. The API is intentionally small to evolve toward zero-copy binary framing (replace base64 chunks with transport-native binary when ready).
