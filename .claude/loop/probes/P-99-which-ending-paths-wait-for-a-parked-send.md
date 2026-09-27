---
file: packages/core/rpc_dart/.dart_tool/probe/ending_paths_overtake.dart
round: 445
commit: 0f3adf45
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
status: valid
---

# P-99 — which ending paths wait for a credit-parked send?

## Why it exists

`RpcChannelTransport` has four send paths and each can end a stream. Round 366
made `finishSending` wait for a credit-parked DATA frame; commit `663cccec` did
the same for `sendMetadata(endStream: true)` and wrote that "every ending goes
through it". `_claimEnding` is called from two sites and `_markFinished` ends a
stream from three more, so the claim needed measuring per path.

## The harness, and why it is NOT P-58's

One table, four arms, each: send 600 bytes into a 512-byte window (passes, the
gate admits on `credit > 0` not on fit), then a 16-byte send that PARKS, then
issue the ending under test without awaiting the parked one. The reading is the
order the peer's `incomingMessages` delivered.

**P-58 says `RpcChannelTransport.pair()` never parks, and that is true of a
DIFFERENT park.** P-58's park is made of LATENCY — waiting for the peer's first
grant — and an in-process pair has the grant ready before the next send asks.
This park is made of VOLUME: credit is driven negative by arithmetic, so it
needs no socket and no RTT. Both statements hold; the shapes are not the same
one, and reading P-58 as "a pair cannot measure parking" would have cost this
round its instrument.

Run the arms on BOTH pairs. `pair()` is the frame codec path and answers
`sendDirectObject` with `UnsupportedError`; only `memoryPair()` carries
zero-copy. An arm that threw read as a passing arm in the first attempt.

## The numbers (round 445)

```
arm                                  before fix   after fix
finishSending            [frame]     held back    held back
sendMetadata(end)        [frame]     held back    held back
finishSending            [memory]    held back    held back
sendMetadata(end)        [memory]    held back    held back
sendDirectObject(end)    [memory]    OVERTAKEN    held back
sendMessage(end) fast    [frame]     0 of 200     0 of 200
```

`OVERTAKEN` reads `[data:600, direct, end, data:16]` — the end reached the peer
while the sender was still waiting to place `data:16`. Fixed it reads
`[data:600, data:16, direct, end]`.

## Measures

The ORDER of arrival at the peer, not a quantity: the index of `end` against the
index of the parked frame in `server.incomingMessages`. Taken on the receiving
transport, which is the side whose count goes wrong in the field report.

## Control

Two, and both are needed.

1. **The ablation** — `_claimEnding`'s call removed in place from
   `sendDirectObject`. The witness flips to OVERTAKEN, which is what makes this
   a bench rather than an observation.
2. **The guarded siblings** — `finishSending` on the same pair kind as each
   witness. They read `held back` in every row, so a witness reading `held back`
   is the rule and not a property of the harness. A witness on `memoryPair`
   whose only control ran on `pair()` would not establish that.

## What it establishes, and what it does not

Establishes: of the four paths that can end a stream, `sendDirectObject` did not
wait and now does; the two that call `_claimEnding` do.

**Does not establish anything about the `sendMessage` fast path.** That arm read
0 of 200 both before and after, and it is VOID rather than clean: the fast path
fires only while credit is positive, and a parked frame means credit is not. So
the arm re-measured the parked branch instead. Reaching it needs a grant landing
in the same turn as a synchronous send — see B-88.
