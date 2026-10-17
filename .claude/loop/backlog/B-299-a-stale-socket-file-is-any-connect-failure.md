---
status: closed (round 882)
round: 880
commit: ecaab2ae
paths: [packages/transport/rpc_dart_socket/lib/src/rpc_socket_server.dart]
probe: none — not measured
reason: risk — a hypothesis from reading the code in round 880, not measured
rank: 6
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

## Closed by round 882

CONFIRMED on macOS and FIXED. A live `RpcSocketServer` in another process,
its isolate stalled, 128 connects queued and the next refused with errno 61:
a second `start()` took its path in 3 ms (2 of 2), and the live server was
unreachable by its path afterwards (P-337). Not reproduced on Linux, where
the queue never refused a connect. The server now holds an exclusive lock on
`<path>.lock` for its lifetime, plus a per-isolate set of claimed paths; a
socket file is replaced only by a server that took that lock. After: the
same arm refused in 4 ms, live server reachable. The EACCES case (a socket
owned by another user) was read, not run: that user's lock file cannot be
opened, so `start()` now throws before probing. What is left is in round
882's `## Not fixed`.

## Owner decision

—
