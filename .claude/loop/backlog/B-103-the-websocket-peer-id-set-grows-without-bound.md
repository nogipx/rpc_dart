---
status: closed (round 494)
round: 494
commit: b27c9594
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart]
probe: P-132
reason: "closed — both sources CONFIRMED against paired controls, 29 per 3 s of heartbeat and 50 per 50 cancelled calls against 0 and 0"
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

## Closed (round 494) — both sources confirmed, fixed by one clause

```
                          peer ids
heartbeat 100ms for 3s    0 -> 29
no heartbeat, 3s idle     0 -> 0     <- control
50 cancelled calls        0 -> 50
50 completed calls        0 -> 0     <- control
```

Both sources the lead names, at exactly the rates it predicts.

**The set had to be made observable first**: `health()` delegated to the inner
transport, which cannot see either of the wrapper's own sets. `peerStreamIds` and
`idsOnThisConnection` are in the details now, which is also what the lead asked
for.

**None of the three sketched fixes was taken, and the first one cannot work.**
Removing the entry in `releaseStreamId` loses to ordering — the trailer arrives
AFTER the release and is re-added. Minting the heartbeat id through the wrapper
fixes only that half. Parity stays rejected for the reason the field's own
comment gives.

What shipped is one clause: `m.methodPath != null`. **A methodPath is what
minting looks like** — it is how a peer opens a call and what the responder
pipeline itself keys on — so neither a pong nor a trailer qualifies, and a
genuine reverse call still does.

**The guard carries this round**, because after the fix every witness reads zero,
which a transport that had stopped recording anything would also read. It drives a
real reverse call through `RpcPeerEndpoint` and blocks inside the handler: the
count is `1` while the peer's stream is open and `0` once answered.

Left standing: the heartbeat still mints and releases through `_inner`, bypassing
the wrapper's sets. It no longer leaks and never needed `_liveHere`, but it is the
same bypass B-130 is about from the other side.

Reasoned but not witnessed: that each stale entry made `_liveHere` true for a dead
id. It follows from that method's two-line body; nothing here drives a send on a
dead id to watch it admitted.
