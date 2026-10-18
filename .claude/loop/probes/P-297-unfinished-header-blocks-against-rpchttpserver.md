---
file: packages/transport/rpc_dart_http/.dart_tool/probe/r811_header_hold.dart
round: 811
commit: 68023a57
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_http/lib/src/peer_watch.dart]
status: stale (526c8d52)
promoted: packages/transport/rpc_dart_http/test/an_unfinished_header_block_is_bounded_test.dart
---

# P-297 — unfinished header blocks against RpcHttpServer

## Measures

`r811_header_hold.dart <conns> <KiB> <seconds> [headerTimeoutMs|none|default] [maxConnections]`:
N raw connections each send a request line and K KiB of header lines and
never end the block; after S seconds it prints the process's RSS growth,
how many connections the server closed, and whether an honest RPC call
still succeeds. A Dart replacement for P-277's Python bench (rule zero).

```
  arm                                  rss peak   closed   honest
  before: 300 x 900 KiB, 20 s          +289 MiB   0/300    ok
  after:  300 x 900 KiB, 20 s          +12 MiB    300/300  ok   (byte bound)
  after:  300 x 260 KiB, 20 s          +103 MiB   0/300    ok   (under the bound)
  after:  300 x 260 KiB, 35 s, 30 s dl +99 MiB    300/300  ok   (deadline)
  after:  300 x 60 KiB, no deadline    +38 MiB    0/300    ok
  after:  300 x 60 KiB, 2 s deadline   +41 MiB    300/300  ok
  after:  300 x 1 KiB, maxConnections 100  -       200/300  UNAVAILABLE
```

## Control

The same connections with 1 KiB of headers: +0 MiB, so the growth is the
header bytes dart:io holds. The 60 KiB pair differs only in the deadline;
the last arm shows the price of a connection cap (honest calls refused
while it is full).
