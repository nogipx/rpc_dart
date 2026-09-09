---
status: open — decided by the owner in round 212, do this instead of reverting 208; not started
round: 212
commit: 5ecb156f
paths: [packages/transport/rpc_dart_http2/lib/**]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/aborted_upload_pool.dart
reason: owner decision — cooperative backpressure is the behaviour wanted, and a plain revert of 208 cannot deliver it
---

# B-15 — cooperative backpressure on http2, via rpc-level grants

The owner revisited B-12 after round 208 shipped and asked whether reverting it
would be better, since cooperative backpressure — throttle the slow consumer
rather than fail its call — is the nicer behaviour.

It is. But a plain revert cannot deliver it, and that is the whole point of this
lead. Round 208 replaced pausing because pausing is what makes package:http2's
uncredited discard fatal: measured in round 207, ONE cancelled stalled call
kills the connection permanently, in both directions, polled 20 s. A revert buys
cooperative throttling and hands back a dead connection on the first `.take(n)`.

## How urgent, measured — round 213

The round-208 refusal was recorded as a guard against a consumer that STOPS.
It is not. Nothing throttles the producer any more, so the un-consumed backlog
grows at the RATE GAP and any gap crosses the window given enough upload.
3000 x 4 KiB uploaded, 4 MiB window:

    fast handler  : completed, consumed 3000 of 3000, 15.4 s   <- control
    slow handler
      (2 ms each) : FAILED RpcStatusException(8), 2.1 s, consumed 67 of 3000
    deaf handler  : FAILED, same status, 1.8 s, consumed 0

The slow handler does nothing wrong. So this is not a nicety: ordinary slow
consumers lose their calls today, and the failure scales with upload size rather
than with misbehaviour.

## What to build

Stop borrowing HTTP/2's window as the backpressure signal, and carry the signal
at the rpc level instead — exactly what `RpcChannelTransport` already does:

- the responder emits `x-window-update` metadata grants as it consumes;
- the caller parks in its own `_fcAwaitCredit` equivalent rather than relying on
  the h2 send window;
- the transport NEVER stops reading, so nothing is ever left pending in
  package:http2's connection queue and the discard bug is unreachable;
- a slow consumer is throttled, and no call is failed for being slow.

The code to port exists and is measured: `channel_transport.dart`'s
`_fcTryConsume` / `_fcAwaitCredit` / `_fcOnGrant` / `_fcCredit`, including the
connection-level pool and everything rounds 206 and 212 fixed in it.

## What it replaces

The round-208 refusal (`_fcRefuseOverrun` on the responder, the matching failure
on the caller). Keep it until the replacement is measured, then remove it in the
same round that lands the grants — not before.

## How it will be judged

P-02 must stay green: a cancelled stalled call must not touch the connection.
And the bound must still hold — `upload_backpressure_test` and
`slow_reader_backpressure_test` on their original numbers.

The witness that the change is worth anything is **P-05**, built in round 213 and
deliberately left RED: its `slow` row must go from "FAILED after 2.1 s, consumed
67" to "completed, consumed 3000", in roughly the time the handler's own rate
implies. Its `fast` row is the control and must not move.

## Cost

Multi-round: it is porting core's flow control onto two transports, with the
existing refusal path removed only once the replacement is proven. Round cap is
230.

## Owner decision

**Taken (round 212): build this; do not revert 208.**
