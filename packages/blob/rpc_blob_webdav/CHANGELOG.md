<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 2.1.0

### Changed

- Requires rpc_dart 6 and rpc_blob 2.3. Two core majors are spanned here: see
  rpc_dart's 5.0.0 and 6.0.0 entries — flow control on by default, an expired
  deadline as `RpcDeadlineExceededException` on every shape, a stream that ends
  without a trailer raising `UNAVAILABLE`, and a handler's bare `Exception` text
  no longer reaching the caller.

## 2.0.0

- Implements `ensureCollection`, `deleteMany` and `headMany` from the
  `rpc_blob` 2.0.0 interface. WebDAV has no batch delete or batch PROPFIND, so
  both are loops — the interface is what changed, not what the protocol can do.
- `collectionSize` returns `Future<int?>`.


# Changelog

## 1.0.0

- Initial release: `WebDavBlobRepository` — a WebDAV-backed `IBlobRepository`.
- Faithful `IBlobRepository`: content ranges, cursor pagination, per-blob
  version + timestamps + user metadata via WebDAV dead properties
  (PROPPATCH/PROPFIND) with graceful degradation.
- dart2js / VM / Flutter compatible (`package:http` + `package:xml`, no
  `dart:io`).
- Auth: HTTP Basic, Bearer, or none.
