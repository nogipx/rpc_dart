---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r717_upload_into_a_deaf_server.dart
round: 717
commit: b005e0d2
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart]
status: valid
---

# P-233 — does a deadline stop an upload the server stopped reading?

A raw `ServerSocket` reads the first chunk and stops reading. It never
answers. A unary call over `RpcHttpCallerTransport` sends 8 MiB with a 1 s
deadline. After 3 s the server resumes reading for 5 s. Run with `melos exec
--scope=rpc_dart_http -- fvm dart run
.dart_tool/probe/r717_upload_into_a_deaf_server.dart`.

## Measures

At the server: the total bytes received and whether the client closed the
socket. A closed socket with a partial total means the abort reached the
socket. A full 8 MiB on an open socket means the client went on uploading
into a call it had already given up.

## Control

`abort.complete()` removed from `releaseStreamId`. A no-deadline arm shows
what a hang reads like. A bare `dart:io` abort arm checks the dependency
apart from the library.

```
  arm                           normal                   abort removed
  8 MiB, deadline 1 s           2432 KiB, closed true    8192 KiB, closed false
  CONTROL no deadline           8192 KiB, closed false   8192 KiB, closed false
  1 KiB, deadline 1 s              1 KiB, closed true       1 KiB, closed false
  dart:io abort at 1 s          2432 KiB, closed true    3136 KiB, closed true
```

Observe for at least 5 s. The release is chained after the cancellation
notice, so a 2 s window reads `false` in every arm.
