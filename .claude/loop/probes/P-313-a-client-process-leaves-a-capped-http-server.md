---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r842_exit_slot.dart
round: 842
commit: 4c753983
paths: [packages/transport/rpc_dart_http/lib/src/peer_watch.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
status: stale (526c8d52)
promoted: no — a CLEAN round; the behaviour it checks is a release that already holds, and a test would need child processes and a 3.5 s settle per arm
---

# P-313 — a client process leaves a capped http server

`fvm dart run <file>` from the repo root. `RpcHttpServer(maxConnections: 1)`;
three `nc` client processes in turn, each either sending a request and
reading the answer (keep-alive) or connecting with stdin closed, and exiting.
After a 3.5 s settle (L-25), one honest raw request. It prints the server's
sockets on the port (`lsof -i`) and the kernel states (`netstat`).
`r842_plain_server.dart` beside it polls a plain `ServerSocket` for the close.

## Measures

Whether a fresh request is answered (`served`) after N clients have left, at a
cap of 1: a slot that outlives its connection reads as REFUSED.

## Control

`maxConnections: null`, and `_onEnded()` ablated in `_WatchedSocket._ended`:

```
arm                               cap 1     no cap   ablated, cap 1
answered, client process exits    served    served   REFUSED
connected, client process exits   served    served   REFUSED
```

In every arm the server held no socket on the port (`lsof`), and the kernel
showed only TIME_WAIT.
