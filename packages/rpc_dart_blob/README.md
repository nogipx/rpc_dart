# rpc_dart_blob

Contract and adapters for streamed blob storage over `rpc_dart`. Think of it as the binary twin of `rpc_dart_data`: optimized for chunked uploads/downloads, checksums, and content types, without forcing base64 inside JSON payloads.

## Quick start

### Server
```dart
final storage = SqliteBlobStorageAdapter.file(
  'blobs.sqlite',
  readChunkBytes: 256 * 1024, // stream read size
);
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
final env = await BlobServiceFactory.inMemory(
  uploadChunkBytes: 128 * 1024,
  maxChunkBytes: 256 * 1024,
);
final client = env.client;
```

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
