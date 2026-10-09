---
status: closed (round 475)
round: 445
commit: 0f3adf45
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
probe: P-118
reason: bench — the arm is VOID, not clean: 0 of 200 because the two preconditions exclude each other except in one turn
---

# B-88 — `sendMessage`'s fast-path ending was never reached

## CLOSED (round 475) — the seam was the RECEIVE side

Round 469 stopped on *"from outside `RpcChannelTransport` every entry point is
async, so no test can be in that turn"*. True of the SEND side; the transport
also LISTENS, and `IRpcMultiplexedChannel` is five members. A
`StreamController(sync: true)` for `incoming` runs `handleInbound` → `_onGrant` →
`wakeAll()` before `add` returns, leaving the woken sender's continuation a
queued microtask — so the next statement is inside the window. No production
change needed to get there.

```
before the grant  [meta, meta, data(64)]
before the fix    [meta, meta, data(64), data(8)+END, data(64)]
after the fix     [meta, meta, data(64), data(64), data(8)+END]
```

The ending overtook the parked frame: the peer was told the stream ended and then
handed a frame on it.

Shipped: the guard round 445 wrote and dropped, now witnessed —

```dart
if (endStream &&
    _parkedSends.containsKey(streamId) &&
    !await _claimEnding(streamId)) return;
```

**`containsKey` first is load-bearing**, not a micro-optimisation: `sendMessage`'s
own comment keeps the fast path synchronous, and an unconditional await would add
a microtask hop to every send with the window off. Guarded by a test that asserts
ordering is unchanged in that configuration.

Canary: the condition disabled reproduces `Expected: a value greater than <4> /
Actual: <3>` with both guards still green. `P-119`.

## The arm is REPAIRED (round 469). The fix is still unwitnessed.

Driven at `RpcFlowController`'s own API, as this lead prescribed — the window is
real:

```
                                    fast path took it   parked sender resumed
a fast-path send in the waking turn        true                 FALSE
CONTROL: nobody contends                   false                TRUE
```

The grant must arrive through `handleInbound`, not `returnCredit` — that one is
the RECEIVE side and never touches `_sendCredit`. And the policy must SEED the
sender (`initialSendWindowBytes` non-null) or `creditFor` stays null,
`tryConsume`'s `streamCredit <= 0` can never fire, and every call returns true.
Both of those produced a second and third void arm before this one worked; the
tell each time was `parked sender resumed=true` in a run where the credit should
have been exactly spent.

Transport-level control: two sends on one stream through the public API arrive
`[meta, data(64), data(64)]`, in order. The ordinary path is not broken.

**What is still missing is a witness AT THE SITE.** The fix changes the ORDER of
two frames on the wire, which needs a caller inside the waking turn, and from
outside `RpcChannelTransport` every entry point is async. That is the same wall
round 445 hit — now explained rather than merely observed — so this lead's own
instruction stands and round 469 obeyed it.

What would change the answer: a seam letting a test run inside the transport's
inbound handling, the turn `handleInbound` runs in. That is a testability change
to `RpcChannelTransport`, not a fix, and whether one line of ordering is worth
one is the owner's call.

Round 445 closed the class B-74 named, except for one site.
`channel_transport.dart:506` — `sendMessage`'s unparked branch — writes its frame
with the end flag and calls `_markFinished`, without claiming the ending. Round
445's probe read **0 of 200 attempts** against it, before and after the fix.

**That zero is void, and the reason is why this is a lead rather than a
negative.** The fast path fires only when `tryConsume` succeeds, which needs
`credit > 0`; a frame parked in `awaitCredit` means credit is NOT positive. So
the two preconditions exclude each other, and every one of the 200 attempts
parked instead — re-measuring the branch at `:494` a second time rather than the
one under test. L-15's shape exactly, and the third instance of it in that one
round.

## What would reach it

`tryConsume` (`flow_controller.dart:189`) admits on `credit > 0` and **never
consults `_sendWaiters`**. So the window is: a grant lands, which completes the
parked waiter; the waiter's continuation is a MICROTASK; a synchronous
`sendMessage(endStream: true)` in that same turn calls `tryConsume` first, wins
the credit, and puts the end out ahead of the frame that has been waiting.

Hammering it from outside did not hit that turn. What probably would: drive
`RpcFlowController` directly rather than through the transport, which is where
two of round 366's three diagnoses came from, and return credit by hand at a
chosen point instead of letting the peer grant.

## Why it may not be worth reaching

Nothing in this library issues two payload sends on one stream where the second
carries the end flag. The only caller of `sendMessage(..., endStream: true)` is
`unary/caller.dart:537`, a unary request whose message is the stream's sole
payload — nothing is parked behind it. Client-streaming ends through
`finishSending` or a trailer, and both claim the ending.

So the exposure is a third party driving `RpcChannelTransport` directly with
concurrent sends on one stream. It is public API in a published package, which is
why this is filed rather than dropped.

**Do not "fix" it without a witness.** Round 445 wrote the guard — a synchronous
`_parkedSends.containsKey` check before the fast path — and dropped it again,
because no canary could kill it. Round 366 dropped a second refusal in
`_fcAwaitCredit` for the same reason. A third unwitnessed guard on this file is
the pattern, not the exception.

## Owner decision

—
