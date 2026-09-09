---
status: open
round: 241
commit: aaa5806d
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: packages/transport/rpc_dart_http2/.dart_tool/probe/reconnect_orphan_rate.dart
reason: risk — the candidate fix did not measurably lower the rate and moved the failure onto the LIVE connection; at ~1.3% no deterministic witness exists, and shipping an unproven change to the connect path is worse than the leak
---

# B-25 — a sequential reconnect orphans a connection about 1.3% of the time

Reported twice by the owner from full-suite runs, as
`concurrent_reconnect_test.dart` -> "GUARD: a later reconnect still opens a new
connection", `Expected: <0> Actual: <1>`. It does not reproduce on demand: the
test passed 6/6 alone, and the whole http2 suite and a whole workspace
`test:unit` passed too.

## What is measured

Bench [P-19](../probes/P-19-sequential-reconnect-orphan-rate.md), 390 cycles of
`connect -> reconnect -> reconnect -> close` on the direct path:

```
5 cycles in 390 left ONE connection open on the server 8 s after close()
0 cycles in  90 through the stalling CONNECT proxy did
```

**The orphan is always a DISCARDED connection, never the live one** — ordinals
[1], [2], [2] on the three cycles that carried the instrumentation. So `close()`
does its job; `reconnect()`'s discard of the connection it is replacing is what
sometimes fails to reach the peer.

This is NOT the defect `concurrent_reconnect_test` already pins. That one needs
two overlapping attempts and is deterministic; this one appears with two
STRICTLY SEQUENTIAL reconnects, and the 400 ms stall that makes the concurrent
race reliable produces zero orphans here.

## The mechanism, as far as it is established

`_guardedConnection` builds the connection with
`http2.ClientTransportConnection.viaStreams(guarded, outgoing)`, not
`viaSocket`. Under `viaStreams` package:http2 does not own the socket: it can
close the outgoing sink and nothing else. `_discardConnection` calls
`connection.terminate()` and stops there. The `destroy` callback that would kill
the socket is built in the same function and is wired only to a header-block
violation.

That is a coherent story for the leak and it is NOT proven.

## The candidate fix, and why it was reverted

Attaching `destroy` to the connection through an `Expando` and calling it from
`_discardConnection` after `terminate()`:

```
                     cycles  orphaned   which
before                 390      5       discarded (1 or 2)
with the destroy call  150      1       the LIVE connection (3)
```

1 in 150 against 5 in 390 is 0.67% against 1.28% — at these counts, noise; 150
cycles expect two orphans if nothing changed. And the single post-fix orphan was
the live connection, a mode that never appeared in 390 cycles before, which is
either a second defect or something the change introduced. Reverted rather than
shipped: this loop does not ship a fix with no failing witness, and a 1.3%
probabilistic defect cannot produce one.

## Owner decision

None yet.

## What would close it

A deterministic reproduction — the shape to look for is what makes the sink
close fail to reach the peer, since that is the difference between the 98.7% and
the 1.3%. Failing that, a rate measurement powered enough to separate 1.3% from
0.65%: roughly 2000 cycles an arm, about 75 minutes each, which is the cost this
lead is deferred on.
