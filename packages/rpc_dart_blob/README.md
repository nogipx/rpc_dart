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
Descriptors returned from S3 include a short-lived presigned download URL (`downloadUrl`). Prefer `presignEndpoint`/`presignPort`/`presignUseSSL`/`presignPathStyle` when the public host differs from the internal one — the URL will be signed directly for the external host. Set `presignRegion` explicitly to avoid any region lookup when generating presigns. `S3BlobStorageOptions` also configures prefix/clock and `presignTtlSeconds` (link lifetime).

## Goals
- Separate contract for blobs (`BlobService`) so `rpc_dart_data` stays focused on JSON records.
- Stream-first API (client-stream upload, server-stream download) with optimistic versioning.
- Pluggable storage adapters (SQLite for dev/tests, S3/MinIO for object storage; bucket must exist).
- Export/import-friendly framing (header + binary chunks) without loading whole files in memory.

## Layout
- `lib/src/models.dart` — descriptors, chunk frames, list/delete/head requests.
- `lib/src/adapters` — storage adapter interface for concrete backends.
- `lib/src/rpc` — contract, caller/responder wiring, service interface (client-stream upload, server-stream download; chunks are base64-framed for now).

## Status
Includes `SqliteBlobStorageAdapter` for local/dev storage (payloads kept in `BLOB` columns with optimistic versioning) and `S3BlobStorageAdapter` for S3-compatible backends (AWS, MinIO, Ceph) storing blobs as `<prefix><collection>/<id>` with metadata-based versioning. `BlobService` provides a default server implementation on top of any `IBlobStorageAdapter`. The API is intentionally small to evolve toward zero-copy binary framing (replace base64 chunks with transport-native binary when ready).
