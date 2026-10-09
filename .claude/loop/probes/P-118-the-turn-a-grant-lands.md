---
file: packages/core/rpc_dart/.dart_tool/probe/the_turn_a_grant_lands.dart
round: 469
commit: 84214e03
paths: [packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-118 — the turn a grant lands

## Why it exists

B-88 is a lead because its predecessor's arm was VOID: round 445 read 0 of 200
against `sendMessage`'s unparked branch, and the zero measured nothing, because
the fast path needs `credit > 0` while a parked frame means credit is not
positive. The two preconditions exclude each other — except in one turn, and the
lead names it: a grant lands, `wakeAll()` completes the waiter SYNCHRONOUSLY, and
the waiter's continuation is a MICROTASK.

So the bench's job is to CONSTRUCT that interleaving rather than race for it. The
lead says how: drive `RpcFlowController` directly.

## The harness

`RpcFlowController` built by hand — it is on no barrel, `channel_transport.dart`
is its only importer in the package, so the probe imports the file. Window 64,
frame 64, so one send spends it exactly.

1. `tryConsume` once: the window is spent.
2. `awaitCredit` for another frame: it parks.
3. The grant lands through `handleInbound` — a connection window update and a
   stream one, which is what a real peer sends.
4. **In that same synchronous turn**, `tryConsume` again. This is exactly what
   `sendMessage`'s fast path does, and `tryConsume` never consults
   `_sendWaiters`.
5. Drain the microtasks and see whether the parked sender got through.

The contending call is the only thing that varies.

## The numbers (round 469)

```
                                    fast path took it   parked sender resumed
a fast-path send in the waking turn        true                 FALSE
CONTROL: nobody contends                   false                TRUE
```

**That is the window.** The credit a parked sender was woken for goes to whoever
calls `tryConsume` first, and the parked sender parks again.

Transport-level control, two sends on one stream through the public API:

```
frames the peer saw: [meta, data(64), data(64)]
```

In order. From outside the transport every call is async, so nothing can land in
the waking turn — which is why 200 attempts all re-measured the parked branch.

## Measures

Whether the contending `tryConsume` returned true, and whether the parked
`awaitCredit` completed. Both are the controller's own answers.

## Control

The same arm with the contending call removed, which is the one line that
differs. It flips BOTH columns, so the result is about the contention and not
about the setup.

**Two earlier versions of this bench were void, and the second is the one worth
carrying.** The first used `returnCredit` to deliver the grant — that is the
RECEIVE side, which accumulates credit to grant to the PEER and never touches
`_sendCredit`, so no parked sender was ever woken. Before that, the policy set
`initialSendWindowBytes: null`, which leaves the sender unseeded: `creditFor`
stays null, `tryConsume`'s `streamCredit <= 0` can never fire, and every call
returns true — an arm that measures "unbounded" and reads like "the fast path
won". **The tell was a third column**: `parked sender resumed=true` in a run where
the credit should have been exactly spent.

## What it establishes, and what it does not

Establishes: the window B-88 describes is real and reachable at the controller's
own API, and the fast path does take credit a parked sender was woken for.

Does NOT establish the transport-level ORDERING consequence — that an ending put
out on the fast path overtakes a parked data frame on the wire. That needs a
caller inside the waking turn, and from outside `RpcChannelTransport` every entry
point is async.

## Reading

rpc_dart — **an interleaving CONSTRUCTED rather than raced for**, which is
what repaired a 0-of-200 void arm. `RpcFlowController` driven at its own API
(it is on no barrel; `channel_transport.dart` is its only importer): spend the
window, park a frame, deliver the peer's grant through `handleInbound`, then
contend in that same synchronous turn. `fast path took it=true, parked sender
resumed=FALSE` against a control at `false/TRUE`. **Two void versions preceded
it and the tell was one extra column**: `returnCredit` is the RECEIVE side and
never wakes a sender, and `initialSendWindowBytes: null` leaves the sender
unseeded so `tryConsume` can never refuse — both read as "the fast path won"
while measuring nothing, and `parked sender resumed=true` with the credit
exactly spent is what contradicted them
