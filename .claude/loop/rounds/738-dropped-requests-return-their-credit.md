---
round: 738
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-01
bench: P-244 — new
commit: yes
release: none
---

# Round 738 — dropped requests return their credit

## Target

RPC-01, last applied in round 558, before message credit (round 709)
existed. Its question, *is credit returned for a frame nobody consumes*, asked
of a path that round 558 never ran. A bidi handler stops reading its requests
but keeps the call open. The pipeline then drops every later request
(`pushRequest`: the sink is closed, `droppedRequests++`).

## Hypothesis

Dropped requests return no credit. They stay owed to the CONNECTION pool for
as long as the call lives, so a few such calls starve every other call on
the connection.

## Before

Probe: `packages/core/rpc_dart/.dart_tool/probe/r738_dropped_requests_hold_the_pool.dart`.
Channel pair with a 64 KiB stream window and a 128 KiB connection pool, N
bidi calls whose handler reads one request and then stops, each client
sending 1 KiB requests. After 2 s, a 1 KiB unary on the same connection.

```
  arm                                      KiB pulled per call   unary
  0 such calls (control)                       -                 pong in 36 ms
  2 calls, handler stops reading (case)        100000, 100000    pong in 12 ms
  2 calls, handler pauses instead (control)    65, 64            HUNG
```

## Mechanism

The hypothesis does not hold. Once the handler's request subscription is
gone, arriving requests are credited as they are dropped, so the sender is
never parked and the pool never drains. The paused arm shows the bench can
see exhaustion. A paused reader legitimately holds one window each, which is
connection-window semantics and not this lens's defect.

## After

n/a — nothing to fix.

## Canary

n/a — no fix. The paused arm is the control that shows the instrument sees a
drained pool.

## The verdict questions

1. Yes: the arms differ only in how the handler stops reading.
2. Yes: HUNG against pong.
3. At the client's generator and a real call.
4. Not zero.
5. No fix, so no witness.
6. n/a.
7. CLEAN.
8. None.
A1. One policy object on both sides of the pair.
A2. Volume.
L1. n/a — no refusal.

## Gate

No library change.

## Not fixed

A sender whose peer handler stopped reading still uploads everything it has
(100 MB per call here). The peer drops it and credits it back. Telling the
sender to stop would need a request-side half-close, which the wire format
does not carry.

## Links

Lens `../lenses/RPC-01-flow-control-credit-on-skip.md` — `applied: [..., 738]`.
New bench `../probes/P-244-dropped-requests-and-the-pool.md`.
