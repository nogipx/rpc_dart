<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# rpc_blob_webdav

WebDAV storage adapter for [`rpc_blob`](../rpc_blob). A `WebDavBlobRepository`
implements `IBlobRepository` against any WebDAV server (Nextcloud, ownCloud,
Apache `mod_dav`, sabre/dav, …), so it drops in wherever `rpc_blob_minio` or
`rpc_blob_sqlite` do.

**dart2js / VM / Flutter compatible** — depends only on `package:http` and
`package:xml`, never `dart:io`. That makes it usable in the browser / Electron
(e.g. an Obsidian plugin) where the S3 adapter's native client can't run.

## Quick start

```dart
final storage = WebDavBlobRepository.connect(
  baseUrl: 'https://dav.example.com/remote.php/dav/files/alice/blobs',
  username: 'alice',
  password: 'app-password',
);

// Use it directly...
final client = IBlobClient.repository(repository: storage);

// ...or serve it over rpc_dart.
final server = BlobServiceFactory.createServer(
  transport: transport,
  storage: storage,
);
await server.start();
```

Auth options:

```dart
WebDavBlobRepository(
  baseUrl: Uri.parse('https://dav.example.com/blobs'),
  auth: WebDavAuth.basic(username: 'alice', password: 'pw'),
  // or WebDavAuth.bearer('token'), WebDavAuth.header('...'), WebDavAuth.none()
);
```

## Mapping

Each collection is a directory under `baseUrl` and each blob id a resource
inside it (`<baseUrl>/<collection>/<id>`). The collection directory is created
on demand with `MKCOL`.

| `IBlobRepository` | WebDAV |
|---|---|
| `writeBlob` | `MKCOL` (once) + `PUT` (+ `PROPPATCH` for metadata) |
| `readBlob` (+ range) | `GET` (+ `Range`) |
| `headBlob` | `PROPFIND` `Depth: 0` |
| `deleteBlob` | `DELETE` |
| `listBlobs` (+ cursor/prefix) | `PROPFIND` `Depth: 1` |
| `listCollections` | `PROPFIND` `Depth: 1` on the root |
| `collectionSize` | `PROPFIND` `Depth: 1`, sum of `getcontentlength` |
| `deleteCollection` | `DELETE` on the directory |

Length, content type, last-modified and etag come from standard PROPFIND
properties. Per-blob **version**, timestamps and **user metadata** are stored as
WebDAV *dead properties* (`urn:rpc-blob` namespace) via `PROPPATCH`, enabling
optimistic concurrency (`expectedVersion`) and metadata round-trips.

## Options

```dart
WebDavOptions(
  trackMetadata: true, // default
)
```

`trackMetadata: true` (default) persists version/timestamps/metadata as dead
properties. This needs a server that supports dead properties (most do); if a
server rejects `PROPPATCH`, the bytes still store — version just stays `1` and
metadata is dropped.

`trackMetadata: false` turns writes into a single `PUT` (no pre-`HEAD`, no
`PROPPATCH`), `version` is always `1`, and `expectedVersion` is ignored — the
right choice for a **content-addressed, immutable** blob store.
