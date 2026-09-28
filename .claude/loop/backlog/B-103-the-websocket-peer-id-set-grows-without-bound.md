---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-103 — websocket caller: `_peerStreamIds` grows without bound and marks dead ids live

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Every inbound id not in `_idsOnThisConnection` is recorded as a peer id and removed only when THIS side sends endStream on it or on reconnect — so trailing frames of cancelled/timed-out calls and every web-heartbeat pong add a permanent entry, and each entry makes `_liveHere` true for an id that is dead.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart:339-341`:

```dart
if (!_idsOnThisConnection.contains(m.streamId)) {
  _peerStreamIds.add(m.streamId);
}
```

Removed only at `:435` (`if (endStream) _peerStreamIds.remove(streamId)`) and on
`_attach` (`:327`). The heartbeat mints its id with `_inner.createStream()`
(`:172`), bypassing `_idsOnThisConnection`, so each pong lands here. A cancelled
call's `releaseStreamId` removes its id from `_idsOnThisConnection` BEFORE the
server's trailer arrives.

## Why it matters

Unbounded growth on a long-lived connection (one entry per heartbeat interval on
web, one per cancelled call everywhere), and the stale-id guard this set exists
for is inverted: `_liveHere(id)` now admits sends on ids the connection has
finished with.

## Witness a round would build

Web (or forced app-level heartbeat) client, interval 100 ms, 10 s idle: size of
`_peerStreamIds` (expose via health details). Second arm: 100 cancelled unary
calls against a handler that answers after the cancel.

## Fix sketch

Remove the entry in `releaseStreamId`; mint the heartbeat id through the wrapper;
or decide by parity (the comment at `:76-81` rejects parity; re-weigh it against
this).

## Owner decision

—
