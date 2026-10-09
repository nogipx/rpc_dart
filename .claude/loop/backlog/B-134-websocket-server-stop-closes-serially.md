---
status: closed (round 530)
round: 530
commit: e4ba8c6b
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
probe: P-163
reason: "CONFIRMED, exactly linear, and FIXED with a `Future.wait` whose failures are caught PER endpoint — the group form abandons the remaining closes on the first error"
---

# B-134 — RpcWebSocketServer.stop() closes endpoints one at a time

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`for (final endpoint in List.of(_endpoints)) { await endpoint.close(); }` — each close awaits the socket close, and dart:io waits up to 5 s for a peer that does not answer the close, so N dead peers cost up to N x 5 s.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart:196-202`.

## Why it matters

Shutdown time linear in dead connections.

## What round 530 measured

```
  arm                                    stop() took
  1 peers, close takes 300ms             316ms
  5 peers, close takes 300ms             1512ms
  20 peers, close takes 300ms            6057ms
  CONTROL 20 peers, close is instant     1ms
```

Bench `../probes/P-163-is-shutdown-linear-in-connections.md`. After: `316 / 304 / 304`.

**The per-peer cost is a stand-in.** The real one is dart:io's close timeout for a peer that
never answers, which is seconds; the rig fixes it small and varies N, because the property
under test is the serialisation. At the real timeout, twenty dead peers is around a hundred
seconds.

## Fix

The sketch, with one thing it did not say: the failure must be caught **per endpoint**, not by
the group. `Future.wait` abandons the remaining futures on the first error, which would leave
endpoints open with nothing left to close them.

The witness also asserts every sink recorded its close was CALLED — fast is what abandoning
them looks like too.

## Owner decision

—
