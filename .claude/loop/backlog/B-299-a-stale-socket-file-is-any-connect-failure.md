---
status: open
round: 880
commit: ecaab2ae
paths: [packages/transport/rpc_dart_socket/lib/src/rpc_socket_server.dart]
probe: none — not measured
reason: risk — a hypothesis from reading the code in round 880, not measured
rank: 4
---

# B-299 — a stale socket file is any connect failure

`RpcSocketServer._removeStaleSocket` reads every `SocketException` from its
probe connect as "refused: nobody is listening", and then deletes the file.
A live server can make that connect fail in other ways too: EAGAIN on
Linux when its accept backlog is full, or EACCES on a socket file owned by
another user. In those cases a second `start()` on the same path deletes
the file of a server that is still running. That server then cannot be
reached by its path.

Unmeasured. On macOS a full Unix-socket backlog may itself give
ECONNREFUSED, which would make the case invisible there. Linux would then
need the Docker image.

## Next step

Fill a live listener's backlog, start a second server on the same path,
and check whether the file survives. Do it on macOS and on Linux.

## Owner decision

—
