---
file: packages/transport/rpc_dart_socket/.dart_tool/probe/r882_busy_server.dart
round: 882
commit: 84189f6b
paths: [packages/transport/rpc_dart_socket/lib/src/rpc_socket_server.dart]
status: valid
promoted: packages/transport/rpc_dart_socket/test/stale_socket_file_test.dart
---

# P-337 — a stalled server loses its socket path

`fvm dart run .dart_tool/probe/r882_busy_server.dart <full|nofill>` from the
package. It spawns itself as a child process that runs an `RpcSocketServer`
on a Unix path with the default backlog, then stalls its isolate
synchronously for 6 s. The parent fills that server's accept queue with
connects until one fails (arm `full`), then calls `start()` on a second
server on the same path, and dials the path after the stall. macOS only: on
Linux the queue never refuses a connect (the raw-listener probe,
`linux/r882_full_backlog_errno.dart`).

## Measures

Whether the second `start()` succeeds, which means the live server's socket
file was deleted; counted in the parent, plus whether the live server is
reachable by its path once its stall ends.

## Control

The mechanism removed: the same stalled server, queue not filled (`nofill`).

```
round 882, before the fix (macOS)
  arm      queued  fill error               second start()  live server after
  nofill   0       -                        refused (8 ms)  reachable
  full     128     Connection refused (61)  STARTED (3 ms)  unreachable (ENOENT)   x2
```
