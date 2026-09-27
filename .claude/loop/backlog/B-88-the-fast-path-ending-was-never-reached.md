---
status: open
round: 445
commit: 0f3adf45
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/ending_paths_overtake.dart
reason: bench — the arm is VOID, not clean: 0 of 200 because the two preconditions exclude each other except in one turn
---

# B-88 — `sendMessage`'s fast-path ending was never reached

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
