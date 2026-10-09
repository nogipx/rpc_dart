---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/three_teardowns_different_subsets.dart
round: 452
commit: b94315eb
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-105 — what each teardown block actually clears

## Why it exists

B-84 names three teardown blocks with different subsets and asks two questions
about what the smaller ones leave behind. **Neither question could be asked
before this round**: `_outgoingPumps`, `_fcOutstanding` and the stream-controller
router were private with no getter, so the three blocks were comparable only by
reading them.

Extending `_buildHealthDetails` with those three counts IS the instrument here,
and it is the part that pays the next round too.

## The harness

A `ServerSocket` that completes the HTTP/2 handshake — empty SETTINGS then its
ACK — and then answers NOTHING. A silent server is the point: the stream stays
mid-flight, so no ending clears the state before the teardown under test runs.

One arm per teardown path, on a stream that has metadata and one payload on it so
a pump and a subscription both exist. `health()` read before and after.

## The numbers (round 452)

```
                    before                        after
releaseStreamId     pumps=1 subs=1 active=1       pumps=0 subs=0 active=0
resetStream         pumps=1 subs=1 active=1       pumps=1 subs=0 active=0   <- leak
resetStream, fixed  pumps=1 subs=1 active=1       pumps=0 subs=0 active=0
```

`fcOutstanding` reads 0 in every row and is NOT evidence here: the silent server
delivers nothing, and only `_fcOnDelivered` charges it. Reaching it needs a peer
that sends a payload the consumer does not take — a different arm.

## Measures

Per-stream state counts from `health().details`: `outgoingPumps`,
`fcOutstanding`, `streamControllers`, `pendingSubscriptions`, `pendingParsers`,
`activeStreams`. Read on the transport, before and after one teardown call.

## Control

`releaseStreamId` on the same stream shape, which has disposed the pump all
along. It reads `1 -> 0` in every run, so a witness reading `1 -> 1` is the path
and not the harness failing to create a pump. The `before` value is asserted in
the test for the same reason: an arm with no pump to lose would pass silently.

## A void arm, recorded so it is not rebuilt

The expensive consequence `releaseStreamId`'s comment names — *"a caller awaiting
sendMessage never unwinds once its stream is gone"* — was NOT reproduced. A
256 KiB `sendMessage` against the 65535-byte default window read
`sendParked=false`: the pump absorbs the write and the future completes without
waiting on the window, so there was nothing parked to strand.

So the leak is confirmed as STATE, not as a hang. Making the hang reachable needs
a pump that applies backpressure, and how much it takes is unmeasured.

## What it does not establish

The third block — the subscription's `onDone` handler — was not armed. It
disposes no pump either, and on the normal path `releaseStreamId` is what cleans
up, so its omission is covered by the pipeline calling that. Whether every
normally-ended stream reaches `releaseStreamId` is a different question and
belongs with the leak audit.

## Reading

rpc_dart_http2 — one arm per teardown path on a stream left MID-FLIGHT, so no
ending clears the state before the path under test runs. A silent server is
the point. **The instrument had to be built first**: `_outgoingPumps`,
`_fcOutstanding` and the stream-controller router were private, which is why
the lead sat unmeasured for 26 rounds — three counts in `health()` made it
askable. Control is `releaseStreamId` on the same shape, `1 -> 0` every run,
and the BEFORE value is asserted too because an arm with no pump to lose would
pass silently. Carries a VOID arm: a 256 KiB send did not park, so the hang
the sibling's comment promises was not reproduced
