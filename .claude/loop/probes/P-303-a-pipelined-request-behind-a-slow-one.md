---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r820_attacker.dart
round: 820
commit: 16b052a6
paths: [packages/transport/rpc_dart_http/lib/src/peer_watch.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart]
status: stale (526c8d52)
promoted: — (two processes and a compiled server; not a unit test)
---

# P-303 — a pipelined request behind a slow one

## Measures

Two processes, both compiled (`dart compile exe`). `r820_server.dart <hold>`:
an `RpcHttpServer` on defaults whose one method answers after `hold`
seconds; prints its port and its own RSS every second, inside
`runZonedGuarded`. `r820_attacker.dart <port> <arm> <n> <kib> <watch>`:
opens n connections; arm `pipelined` sends a complete request 1 to the slow
method and then an unfinished header block of `kib` KiB for request 2;
arm `first` sends only the unfinished block (round 811's case). Prints the
connections the server closed and the KiB whose flush completed.

```
  hold 30 s, n 5, 20000 KiB offered, 8 s
  arm         closed   accepted     server RSS
  first       5        4576 KiB     9 MiB
  pipelined   0        10595 KiB    11 MiB
```

The pipelined block is accepted by the kernel's socket buffers (about 2 MB
per connection on macOS loopback), not by the server: dart:io stops reading
the connection while request 1 is in flight.

## Control

The `first` arm: round 811's bound closes all five. Server RSS is the same
in both arms.

The first version of this bench ran attacker and server in ONE process and
read +373 MiB for 200 pipelined connections against none for `first`: the
attacker's own unflushed writes, held in Dart memory while the server did
not read, and freed in the `first` arm because those connections were
closed. The number was taken on the wrong side.
