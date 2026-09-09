---
status: awaiting owner
round: 217
commit: 576f1815
paths: [packages/core/rpc_dart/lib/src/resilience/client_connection.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/watermark_survives_a_decorator.dart
reason: owner decision — both candidate fixes change behaviour in a resilience class, in opposite directions
---

# B-17 — a decorator erases the stream-id watermark, and a live call dies

`RpcClientConnection` carries a stream-id watermark across transport swaps so a
replacement cannot hand out an id a dead call still holds. Both hops guard on
`is IRpcStreamIdSequence` and return silently when it is absent, so an
application decorator that forwards every `IRpcTransport` member and declares
nothing else erases the whole mechanism.

Measured (P-09), with the factory returning a plain decorator instead of the
transport:

    factory returns          id before   id after   handlers ended
    the transport itself         1           3          0 -> 0
    a plain decorator            1           1          0 -> 1

The last column is the defect: a live bidirectional call's request stream was
half-closed by an unrelated dead call's teardown, and the server finished
serving it. Silent, and it is the exact scenario the watermark exists for.

Round 209 found the same class on http2 with `IRpcFlowControlled`, and the fix
there was `_preserveCapabilities`. **That is not available here**: http2 wraps a
decorator around a transport it still holds, whereas this factory returns the
decorator with the real transport hidden inside it. There is nothing to fall
back to.

## The two candidates

1. **Generation-tag the ids.** The proxy issues every id through
   `createStream()`, so it can record which transport generation each belongs to
   and drop stream-scoped operations for ids from a retired one.
   Capability-independent, so it also covers a stale id used when the watermark
   WAS carried.
   Cost: a stale `finishSending` becomes a silent no-op rather than reaching
   anything, and it adds a per-id map on the hot path — bounded by our own
   traffic, pruned on release.

2. **Refuse the transport at attach.** If the factory returns something that is
   not `IRpcStreamIdSequence`, fail loudly instead of connecting.
   Cost: an application with a decorator that works today stops connecting at
   all. Breaking, but impossible to get silently wrong.

Warning and carrying on is not a candidate: it leaves the data loss in place,
and the config's bar rules out diagnostics as a round's product.

## Owner decision

**Both: tag, and warn on attach.** (Asked and answered in round 217.)

Generation-tag the ids so the data loss is gone regardless of the capability,
AND log a warning at attach when the factory's transport does not implement
`IRpcStreamIdSequence`, so the operator learns their decorator is dropping it.
No breakage, and no silent degradation.

Notes for the round that carries this out:

- The tag is the load-bearing half and needs the witness; the warning is a
  diagnostic and must not be mistaken for the fix. P-09's `handlers ended`
  column has to go `0 -> 0` in BOTH rows.
- Two canaries, one per half, per L-01 — and check the tagging half does not
  mask the warning half's witness.
- Watch the GUARDs in `client_connection_stream_ids_test.dart`: "calls still run
  across repeated swaps" and "a half-close on the CURRENT transport is still
  sent". Generation-tagging must not turn an ordinary id into a no-op, which is
  exactly what that second guard exists to catch.
- The map is keyed by ids the proxy itself issued, so it is bounded by our own
  traffic — prune it on `releaseStreamId`, and read round 212 first: a late
  arrival re-creating an entry after teardown is the trap that family has
  already sprung once.
