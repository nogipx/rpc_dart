---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/header_hold_attacker.py
round: 782
commit: 5db1dd59
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart]
status: valid
---

# P-277 — held request header blocks

## Measures

Two processes. The server is one of
`rpc_dart_websocket/.dart_tool/probe/header_flood_server.dart` (an
`HttpServer.bind` handed to `rpcWebSocketConnections`, defaults) or
`rpc_dart_http/.dart_tool/probe/header_hold_server.dart` (`RpcHttpServer`,
defaults), printing RSS and peak; `footprint -p` read from outside. The
attacker, `header_hold_attacker.py port n kib seconds`, opens `n`
connections, sends a request line and `kib` KiB of 1 KiB headers, never
ends the block, and after `seconds` counts how many the server closed.

```
  server                n    KiB   peak rss    footprint 20s / 110s   closed after 140s
  websocket (io)        300  900   +313 MiB    318 MB / 318 MB        0 of 300
  RpcHttpServer         300  900   +311 MiB    -                      0 of 300
  websocket, control    300  0     +3 MiB      -                      0 of 300
```

One connection streaming headers without stopping is cut by dart:io after
about 3 MiB sent (`header_flood_attacker.py port flood 8`): +6 MiB peak.

## Control

`kib = 0`: the same 300 connections, the same request line, held as long;
only the header volume is removed. +3 MiB against +313 MiB.
