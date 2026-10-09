---
file: packages/core/rpc_dart/.dart_tool/probe/inside_the_waking_turn.dart
round: 475
commit: 37b64f3a
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
status: valid
---

# P-119 — inside the waking turn

## Why it exists

P-118 proved the flow-control window exists at `RpcFlowController`'s own API and
could go no further: the transport-level consequence is an ORDER of two frames,
which needs a caller inside the turn a grant lands, and round 469 concluded that
was impossible because *"from outside `RpcChannelTransport` every entry point is
async"*.

True of the send side. The receive side is the seam.

## The harness — a synchronous channel, and nothing else

`IRpcMultiplexedChannel` is five members: `isClosed`, `supportsZeroCopy`,
`incoming`, `send`, `close`. The probe implements it with
`StreamController.broadcast(sync: true)` for `incoming` and a `List<String>` for
`send`.

**`sync: true` is the whole bench.** `incoming.add(grant)` runs the transport's
listener — `handleInbound`, `_onGrant`, `wakeAll()` — before `add` returns, so
the woken sender's continuation is a queued microtask and the next statement is
inside the window. No production code changes to get there.

The sequence:

1. window 64, one frame spends it;
2. a second frame parks (unawaited, and asserted as still parked);
3. `grantConnection` then `grant`, both synchronous;
4. **same turn**, an `endStream: true` send — the fast path, since credit is now
   positive;
5. read the order the channel recorded.

The policy must SEED the sender (`initialSendWindowBytes`) or `tryConsume` never
refuses and nothing parks — the trap P-118 paid for twice. Grace off, so the
legacy timer cannot hand out credit on its own.

## The numbers (round 475)

```
before the grant  [meta, meta, data(64)]
before the fix    [meta, meta, data(64), data(8)+END, data(64)]
after the fix     [meta, meta, data(64), data(64), data(8)+END]
```

## Measures

The ORDER of frames the transport handed to the channel, as the index of the
`+END` frame against the index of the parked one. Recorded inside `send`, which
is the last thing the transport does before the wire — so it is the transport's
own output, not an inference from timing.

## Control

The parked frame is asserted BEFORE the grants: `[meta, meta, data(64)]` with
nothing else. Without that, "the ending came second" would be equally consistent
with the second frame never having parked at all — which is exactly how round
445's 0-of-200 went void.

The two guards in the witness test are the other half: ordering is unchanged with
flow control OFF, and an ending with nothing parked is not delayed.

## What it establishes, and what it does not

Establishes: the fast-path ending overtakes a parked frame on
`RpcChannelTransport`, and the `containsKey`-guarded claim fixes it without
adding an await to the hop-free path.

Does NOT cover http2 or HTTP/1.1, which have their own send paths and no
equivalent seam here. Whether they share the shape is a separate question.

## Reading

rpc_dart — **the seam is the RECEIVE side, and it is free.** P-118 measured
the flow-control window at the controller's API and stopped, because the
transport-level consequence needs a caller inside the turn a grant lands and
"every entry point is async". True of the SEND side: the transport also
LISTENS, `IRpcMultiplexedChannel` is five members, and a
`StreamController(sync: true)` for `incoming` runs `handleInbound` →
`_onGrant` → `wakeAll()` before `add` returns — so the woken sender's
continuation is a queued microtask and the next statement is in the window.
Measures the ORDER the transport handed to the channel, recorded inside
`send`. **The control is asserting the frame is still parked BEFORE the
grants**: without it, "the ending came second" is equally consistent with
nothing having parked, which is how round 445's 0-of-200 went void. Policy
must SEED the sender or nothing parks at all
