---
status: closed (round 350) — bounded the buffer; pacing was the wrong tool
round: 281
commit: e481520a
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/metadata_is_never_paced.dart
reason: "owner decision (round 282 measured it) — both candidate fixes change behaviour on the path every transport shares: charging metadata against the window makes sendMetadata able to block, and bounding the per-stream controller turns a flood into a stream failure rather than backpressure"
---

# B-28 — metadata is exempt from flow control at both ends

Round 280 left this named with line numbers: `_fcOweConnection`, `_fcDischarge`
and `_fcOnDelivered` charge `payload?.length ?? 0` at six sites. The worry was
an ASYMMETRY — the sender spending window on a frame the receiver credits back
at zero, which is the under-crediting family of rounds 206 and 266 and wedges a
connection permanently.

**Refuted by reading both ends.** `ChannelTransport.sendMetadata` (line 518)
spends no window at all — no `_fcTryConsume`, no `_fcAwaitCredit` — and
`_fcOnConsumed` (line 1012) does `if (bytes == 0) return;`. Nothing is charged
and nothing is credited, so nothing leaks. The six sites are consistent with
each other.

## What is left, and why it still matters

Metadata frames are outside flow control entirely. A peer can push them as fast
as it can write, and the send window never applies. After rounds 279 and 280
something does stop it — the queue's byte bound, now that it weighs metadata and
charges per header — but that is a HARD bound: the connection fails with a
framing error rather than the peer being throttled.

So the open question is not "is there a leak" but **which mechanism catches a
metadata flood, and is failing the connection the right answer for a LEGITIMATE
client** that simply sends metadata faster than the server consumes it. A
hostile peer being disconnected is fine. A slow-consumer client being
disconnected where a payload flood would merely have been paced is not.

## The probe that settles it

Two arms against a real channel transport with flow control ON and a consumer
that does not read:

- `payload`: frames of N payload bytes. Expected — the sender parks in
  `_fcAwaitCredit` once the window is spent. The control, and it is what proves
  the bench can see throttling at all.
- `metadata`: frames of the same wire size carried as headers. Expected — the
  sender never parks; measure how many land, and WHICH mechanism finally stops
  it (the queue's byte bound, the event cap, or nothing).

Report frames landed, whether the sender ever parked, and the error the
connection dies with. `P-21`/`P-29`'s controller fill is the wrong shape here —
this needs the transport, because the question is about the send path.

If the answer is "the connection is failed", the fix is a policy question rather
than a defect: either charge metadata against the window (making it pace) or
document that metadata is unpaced and bounded only by the queue. Ask before
choosing — it changes behaviour for existing clients.

## Round 282 measured it, and the prediction was half wrong

```
arm       frames offered  sends completed  sender PARKED  connection error
payload              200                8           true              none
metadata             200              200          false              none
metadata            4000             4000          false              none
```

Metadata is indeed never paced — 4000 sends, 32 MiB, none blocked. But the
predicted backstop **does not exist**: no bound fired at twice the queue's
16 MiB ceiling. The queue's byte bound is on `_incoming`, which only queues
while nobody listens; these frames go to the per-stream view from
`getMessagesForStream`, a plain `StreamController` that is unweighed and
uncapped. Flow control is the only thing in front of it, and metadata walks past
flow control.

So this is an unbounded buffer reachable by an unauthenticated peer, not a
hard-versus-soft failure question. See
`../rounds/282-metadata-is-never-paced.md`; bench
`../probes/P-31-metadata-is-never-paced.md`.

## Owner decision

**Taken: fix it (round 350).** Of the two candidates the lead named, only one
survives contact with the protocol.

**Charging metadata against the send window is the WRONG tool, and HTTP/2 says
so.** Flow control there applies to DATA only; HEADERS are exempt by design,
because a control frame that cannot be sent deadlocks the stream it is trying to
end — a trailer waiting on a window the peer will only open once it sees that
trailer. Pacing metadata would diverge from the protocol this library implements
and introduce that deadlock.

So the fix is the other one: **bound the buffer**, which is also how the protocol
bounds headers (`SETTINGS_MAX_HEADER_LIST_SIZE`, not the window).

`RpcChannelTransport` now charges every frame queued into a per-stream controller
against `effectiveMaxBufferedBytes`, weighed by `RpcTransportMessage.bufferedBytes`
— the weigher round 279 already wrote for the other queue, whose own doc says
"one home for the rule, because every transport buffers these". Over the bound,
the STREAM fails with `RESOURCE_EXHAUSTED`; the connection survives, because a
peer flooding one call must not take down the others sharing the socket.

Measured, 200 metadata frames of ~8 KiB against a 256 KiB bound:

```
                                    before      after
errors on the stream                none        RESOURCE_EXHAUSTED
transport closed                    no          no
ordinary exchange (default policy)  ok          ok
consumer that KEEPS UP, 200 frames  ok          ok
```

The last row is the one that makes it a buffer bound and not a throughput cap.

Guarded by `packages/core/rpc_dart/test/streams/metadata_flood_is_bounded_test.dart`.
