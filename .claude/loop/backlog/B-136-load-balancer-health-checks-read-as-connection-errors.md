---
status: closed (round 532)
round: 532
commit: a016a327
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart, packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
probe: P-165
reason: "CONFIRMED one for one and FIXED. Non-upgrade requests are answered before the transformer sees them; the origin gate still runs FIRST and the bounded drain is still used, both because a first attempt that reordered or removed them failed an existing test"
---

# B-136 — a plain HTTP request to the websocket server is logged as a connection error

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Every request goes to `WebSocketTransformer`, which answers 400 and errors the connections stream; each health check produces an error log and an `onConnectionError`.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/websocket_io_connections.dart:90-102`, `rpc_websocket_server.dart:125-135`;
allowed origins are also re-normalised per handshake (`:124-126`).

## Why it matters

Error-level noise at the load balancer's probe rate.

## What round 532 measured

```
  arm                            error logs   onConnectionError   peer saw
  10 plain GETs                  10           10                  400
  CONTROL 10 real handshakes     0            0                   upgraded
```

Bench `../probes/P-165-what-does-a-health-check-cost.md`. After: `0  0  400`.

The peer column is what keeps the fix honest — the answer was already correct, so only the noise
may move. **Mechanism read from the SDK**: `_upgrade` sends 400 and returns
`Future.error(WebSocketException(...))`, which `bind` forwards to the OUTPUT stream, i.e. the
server's `connections` stream.

## Fix

The sketch, with two corrections it needed:

**Not "first".** Checking the shape before the origin gate answers a cross-origin probe 400 —
"wrong shape" about a request refused on identity — and `origin_guard_test` pins 403 there. The
gate runs first; the shape check second.

**The drain cannot be skipped.** Answering without draining looked strictly better (it avoids
putting a bounded hold on ungated servers), but `await response.close()` on a request with an
unread body never completes, so the peer got nothing. Caught by
`a_refused_upgrade_has_a_deadline_test.dart`. The existing bounded drain is reused for both
statuses.

Origins are pre-normalised as the sketch says — a hygiene change with no witness of its own;
equivalence is what `origin_guard_test`'s case-insensitivity cases assert.

**Wider than before**: the bounded drain now applies on every server, not only gated ones, since a
non-upgrade request is the only kind carrying a body. Same bound, wider surface, documented.

## Owner decision

—
