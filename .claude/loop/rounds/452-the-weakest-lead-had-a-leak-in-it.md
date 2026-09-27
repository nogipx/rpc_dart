---
round: 452
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-25
bench: P-105 — new
commit: yes
---

# Round 452 — the weakest lead had a leak in it

## Target

B-84, which the backlog calls "the weakest of B-70's remainder" and the owner
decided to take as VERIFICATION — answer its two measurable questions, and if
both come back clean close it as a negative in `checked/`.

One did not come back clean.

Scope: the two questions as filed. The third teardown block is named in
`## Not fixed` rather than left unmentioned.

## Hypothesis

`resetStream` and the subscription's `onDone` handler clear smaller subsets than
`releaseStreamId`. If the missing pieces matter, a stream torn down by the
smaller paths leaves flow-control state or a live pump behind.

## Before

```
                before                      after
releaseStreamId pumps=1 subs=1 active=1     pumps=0 subs=0 active=0
resetStream     pumps=1 subs=1 active=1     pumps=1 subs=0 active=0
```

Probe:
`packages/transport/rpc_dart_http2/.dart_tool/probe/three_teardowns_different_subsets.dart`

**Neither of B-84's questions could be ASKED before this round.**
`_outgoingPumps`, `_fcOutstanding` and the stream-controller router were private
with no getter, so the three blocks were comparable only by reading them — which
is why a lead about them sat unmeasured for 26 rounds inside B-70. Three counts
added to `_buildHealthDetails` is the instrument, and it pays the next round too.

The lead's own arithmetic was also short: it lists `_fcForget` as the thing
`releaseStreamId` adds. It adds TWO things — `_outgoingPumps.remove(...).dispose()`
as well, and that is the one that leaks.

## Mechanism

`resetStream` is the path a CANCELLATION takes. It removed the subscription, the
parsers and the stream controller, and left the outgoing pump in the map —
holding whatever was queued for a stream that no longer exists.
`releaseStreamId`'s own comment states the rule it was missing: *"Release
anything parked on the server's window first, or a caller awaiting sendMessage
never unwinds once its stream is gone."*

## After

`resetStream` reads `pumps 1 -> 0`, matching `releaseStreamId`. `_fcForget` was
added in the same two lines, in `releaseStreamId`'s order: pump first, then the
subscription.

## Canary

The two lines removed in place:

    Expected: <0>
      Actual: <1>
    cancelling a call goes through resetStream; leaving the pump behind holds
    whatever was queued on a stream that no longer exists

`+1 -1`, with the `releaseStreamId` control green — so the witness is the path and
not the harness failing to create a pump. The test also asserts the BEFORE value
is 1, because an arm with no pump to lose would pass silently.

## Gate

`melos run analyze` SUCCESS. `test:unit` SUCCESS over 14 packages;
`rpc_dart_http2` 243 passed, up two. `format:check` and `license:check` SUCCESS.
In the package: `analyze lib test` clean, full suite 243 with 0 failures.

## Not fixed

**The hang was not reproduced, so the leak is confirmed as STATE and not as a
stall.** A 256 KiB `sendMessage` against the 65535-byte default window read
`sendParked=false` — the pump absorbs the write and the future completes without
waiting on the window. Making `releaseStreamId`'s stated consequence reachable
needs a pump that applies backpressure, and how much it takes is unmeasured. That
is the fourth void arm in this block of rounds (L-15).

**`fcOutstanding` is not evidence in this bench.** It reads 0 in every row,
because the silent server delivers nothing and only `_fcOnDelivered` charges it.
`_fcForget` was added to `resetStream` on the strength of the sibling's shape, not
on a measurement — stated plainly rather than implied by the diff.

**The third block, the subscription's `onDone` handler, was not armed.** It
disposes no pump either; on the normal path `releaseStreamId` is what cleans up,
so its omission is covered by the pipeline calling that. Whether every
normally-ended stream reaches `releaseStreamId` is a different question and
belongs with the leak audit (C-18).

## Links

- RPC-25 — three near-copies, and the divergence that bit was the one the lead's
  arithmetic missed
- P-105 — what each teardown block actually clears
- B-84 — closed by this round
- L-15 — a void arm reads like a clean one; the hang arm here is one
- RPC-15's round-396 note — when an inventory's instrument cannot reach every
  item it lists, extend the instrument; it is one line and pays forward
