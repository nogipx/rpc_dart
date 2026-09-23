---
status: closed (round 234)
round: 234
commit: c327a2ce
paths: [packages/transport/rpc_dart_websocket/lib/**]
probe: P-13
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

## Round 233 did the first third — do not redo it

```
  read in full     rpc_websocket_channel.dart          251 lines
                   rpc_websocket_server.dart (resources) 365
  grep only        websocket_io_connections.dart        249
  NOT READ         websocket_caller_transport.dart      493   <- start here
```

Settled, with the reasons in round 233's record:

- **RPC-14 is absent, not guarded**: `.timeout(` / `Timer` / `Completer` return
  **0 hits** across the whole package. The same grep found four sites in
  `rpc_dart_isolate`, so the zero is real.
- Channel `close()` and `closeForProtocolError()` are idempotent and both avoid
  the measured `_incoming.close()` deadlock.
- `_endpoints` is removed AND closed on disconnect, on both branches.
- Every detached observability callback goes through `_notify`, which exists
  because a throw there reaches the root zone.

**`websocket_caller_transport.dart` is where to start.** It is the largest file,
it holds `reconnect()`, and this package's last two defects both lived there.

## Round 234 read it, and it held a third — CLOSED

The rescan is done: all nine `lib/` files have now been read or swept, and the
one 233 named produced a defect of exactly the shape 233 predicted. `reconnect()`
read the id cursor off a transport that, on a peer-started drop, had already
rewound it as it closed itself — ids 1 then 1 instead of 1 then 3, and a dead
call's `finishSending` ended a live one (handlers ended 1 -> 2). Fixed in core at
the reset; see `../rounds/234-the-reconnect-nobody-drives.md` and lens RPC-03.

The lead's own instruction is what worked and is worth keeping for the next
package: **rescan rather than work from a list** — and, from
`../lessons/L-06-the-path-the-owner-drives.md`, drive the lifecycle event from
the PEER's side, where the convenient tests never go.

## Owner decision

—
