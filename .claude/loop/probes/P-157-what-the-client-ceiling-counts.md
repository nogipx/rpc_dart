---
file: packages/core/rpc_dart/.dart_tool/probe/b128_client_ceiling_after_half_close.dart
round: 520
commit: 7cdaabf6
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-157 — what does the client's maxActiveStreams count?

## Why it exists

A unary call half-closes as soon as its request is out and then waits. If the slot is
released there, the ceiling bounds request-SENDING rather than outstanding calls —
which is not what the name says and not what an operator setting it expects.

B-75 measured this ceiling holding for calls started synchronously. That does not
cover calls that have already half-closed, which is the case here.

## The harness

Four unary calls against a handler parked on a completer, so every call is
outstanding but none is sending. Then four more, against a ceiling of four.

**Each SIDE carries its own policy, over a hand-built byte pipe.** That is the whole
correctness of the rig: `RpcChannelTransport.pair(policy:)` gives both sides the same
one, and a server refusing at ITS ceiling looks identical from the caller. The lead is
about the client's accounting.

## The numbers (round 520)

```
ceiling on BOTH sides      4 refused with RESOURCE_EXHAUSTED
ceiling on the CLIENT only 0 refused — all eight calls completed
```

## Measures

How many of the second four are refused with RESOURCE_EXHAUSTED while the first four
are still outstanding.

## Control

**The both-sides run IS the control, and it was the first thing measured.** It shows
the ceiling mechanism works, the rig can produce a refusal, and four parked calls do
reach a limit somewhere — so the zero in the client-only run is the client declining
to count, not the rig failing to provoke.

Without it, `0 refused` is equally consistent with a probe that never filled
anything.

## What it establishes, and what it does not

Establishes: the client's `maxActiveStreams` does not bound outstanding calls. Four
calls awaiting responses leave four slots free, and a second batch is admitted in
full. The server's ceiling, on the same run, refuses exactly those four — so the two
sides count different things under one name.

Does NOT establish where the slot should be released instead, or what releasing it
later costs. Nothing here exercised `releaseStreamId` or a terminal inbound frame.

Does NOT cover the streaming shapes. A client-stream call holds its request stream
open, so it may well be counted for its whole life — untested.

## Reading

rpc_dart — **each SIDE carries its own policy, over a hand-built byte pipe,
and that is the rig's whole correctness.** `RpcChannelTransport.pair(policy:)`
gives both sides the same one, and from the caller a server refusing at ITS
ceiling is indistinguishable from a client doing so — the first run produced
`4 refused` and the lead looked refuted. The both-sides run is now kept as the
CONTROL: it proves the mechanism works and the rig can provoke a refusal, so
`0 refused` on the client-only run is the client declining to count rather
than the probe failing to fill anything.
