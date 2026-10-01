---
status: open
round: 535 (items 1, 3 and 6's unhandled future examined; four groups left)
commit: 5e2af858
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_channel.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/transport/rpc_dart_websocket/lib/src/ws_open_stub.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart, packages/transport/rpc_dart_websocket/lib/src/websocket_responder_transport.dart]
probe: P-168
reason: "cost — split and decided in round 597: two owner-requested items left, the connection cap (6d) and a headers callback re-evaluated per reconnect (4). Items 6a-6c fixed in 597; 2, 5 and 7 closed by reading"
---

# B-139 — websocket: smaller defects and hygiene

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Close order, dead table rows, a duplicated annotation, headers captured once, an analyzer workaround, duplicated server branches, an ignored callback, a dropped parameter, no connection cap, an unhandled close future, a pure forwarder.

## The shape

1. `rpc_websocket_channel.dart:242-244` — `close()` cancels the read subscription
   before `sink.close()`; dart:io then cannot read the peer's close reply and
   (unverified) falls back to its 5 s timer.
2. `rpc_websocket_channel.dart:31-32` — rows for null/1000/1001/1005/1006 are
   unreachable; `saidNothing` filters them first.
3. `websocket_caller_transport.dart:465-471` — `@override` twice on
   `sendDirectObject`.
4. `websocket_caller_transport.dart:287-294` — `connect()` captures `headers` once
   for every reconnect; an expiring token cannot be refreshed.
5. `ws_open_stub.dart:61` — `final _ = (pingInterval, enableCompression, headers);`
   allocates a record to silence the analyzer.
6. `rpc_websocket_server.dart:339-367` — peer and responder branches duplicate
   creation and `sink.done` wiring; `onEndpointCreated` is silently ignored when
   `onPeerEndpointCreated` is set; `createWithContracts` drops `logController`; no
   cap on connections; `channel.sink.close()` at `:380` is neither awaited nor
   given an error handler.
7. `websocket_responder_transport.dart` — forwards every member to
   `RpcChannelTransport`, hiding any capability core adds later (its own doc names
   the risk); a factory returning the channel transport avoids it.

## Why it matters

Small, but items 1 and 6's unhandled future are behaviour, not style.

## What round 535 found — the grading is backwards

**Item 1 REFUTED.** The close order costs nothing against a peer that answers:

```
  arm                                   close() took (min of 5)   all
  as shipped: cancel, then sink.close    0ms                      [4, 0, 0, 0, 0]
  swapped:    sink.close, then cancel    0ms                      [0, 0, 0, 0, 12]
  CONTROL raw dart:io WebSocket.close    0ms                      [0, 0, 0, 0, 12]
```

Bench `../probes/P-168-what-does-a-clean-close-cost.md`. The control — the raw SDK close, no channel
— is the same zero, which is what makes the refutation mean something. Cancelling the subscription
does not stop the handshake: the SDK's close and ping machinery sits BELOW the subscription, in the
transformer rather than in the listener.

**Item 3 REFUTED by reading**: one `@override` on `sendDirectObject`, not two.

**Item 6's unhandled future FIXED, and it was the real one.** `_handleConnection`'s failure path ended
in a bare `channel.sink.close()` — unawaited, no error handler — in a method that runs in the accept
loop's event handler, the ROOT ZONE this file's own comments name four times. A close rejecting is the
state a failed setup tends to leave a socket in. Now guarded like the refusal path eighty lines above
it, with `Future.sync` so a synchronous throw is covered too.

## Still open — four groups, and split them first

- **item 2** (mapping rows said to be dead): a judgement call and probably wrong. The rows encode the
  intended mapping, a test pins them, and deleting them makes `_ => unknown` the answer for a clean
  close the moment the function gains a second caller. Round 528 also made 1002 reachable, which this
  item predates.
- **item 4** (`connect()` captures `headers` once, so an expiring token cannot be refreshed): a
  FEATURE — a headers callback — not a defect, and the code argues deliberately for reusing them.
  Features leave the loop by the B-01 precedent.
- **item 5** (a record allocated to silence the analyzer): a documented deliberate choice, once per
  connect.
- **item 6's other five sub-points** (duplicated branches, `onEndpointCreated` ignored in peer mode,
  `createWithContracts` dropping `logController`, no connection cap) and **item 7** (the responder
  transport forwarding every member). The connection cap is the one with plausible severity; nothing
  has measured it.

## Round 597 — split, and three fixed

`../rounds/597-the-callback-that-never-ran.md` has the table. Fixed: both endpoint
callbacks now throw `ArgumentError` (6b), `createWithContracts` takes
`logController` (6c), the branches are merged (6a). Closed by reading: 2 (keep the
rows), 5 (deliberate), 7 (the wrapper hides only `IRpcReconnectableTransport`).

## Owner decision

Session of round 597: 6b — throw `ArgumentError`; implement 6a, 6c, 6d (connection
cap) and 4 (headers callback re-evaluated per reconnect).
