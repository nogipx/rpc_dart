---
status: open
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**]
probe: —
reason: "methodological: the lead list in private memory went stale; the work is to rescan the package"
---

# B-06 — websocket: the old lead list went stale, rescan the package

The list of open websocket leads in the memory corpus has gone stale in full:
both remaining items are closed inside that same file.

- Fragmentation of large messages — measured clean in round 64: 1 KiB → 16 MiB,
  the content checked by DIGEST rather than by length (a reordering bug passes a
  length check); 16 MiB in 146 ms.
- Server-side keepalive — shipped in round 63:
  `rpcWebSocketConnections(HttpServer, {pingInterval})` in
  `package:rpc_dart_websocket/io.dart`.

**On this package, work by rescanning it rather than from a list.** That is how
the orphaned-socket defect on every `reconnect()` retry was found: one retry — 0
alive, two — 1, three — 2.

## Owner decision

—
