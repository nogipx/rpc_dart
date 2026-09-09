---
round: 241
verdict: DEFERRED
packages: [rpc_dart_http2]
lens: RPC-21
bench: P-19 — new
commit: no
---

# Round 241 — the discard that sometimes does not land

## Target

The owner reported a failing test from a full-suite run, twice:
`concurrent_reconnect_test.dart` -> "GUARD: a later reconnect still opens a new
connection", `Expected: <0> Actual: <1>`. A connection outliving `close()` by
more than eight seconds is a connection leak, which is above the severity bar,
and it was not on the known-flake list — so writing it off was not available.

Taken under RPC-21 (drive the lifecycle twice), which had never been applied in
this journal and whose observable is exactly this: drive the lifecycle more than
once and assert the STATE afterwards rather than the return value. Passed over
the never-applied RPC-06 (needs a booted device) and the five stale sweeps: a
reported failure with a reproduction condition outranks a re-measurement.

## Hypothesis

Either the report is noise from a loaded machine, or a sequential reconnect
leaks a connection at a rate low enough to hide in a single run. Falsifiable in
one direction by enough cycles.

## Before

First, it is not noise, and it is not the concurrent-overlap defect the test
file already pins:

```
arm            cycles  orphaned   which connection of 3
stalled proxy    90       0       —
direct          390       5       [1], [2], [2] (+2 before the ordinal existed)
```

Probe: `packages/transport/rpc_dart_http2/.dart_tool/probe/reconnect_orphan_rate.dart`
(P-19). A cycle is `connect -> reconnect -> reconnect -> close`, then the
server's own open/close counters polled to an 8 s deadline.

Two things the numbers say that reasoning would not have. The 400 ms stalling
CONNECT proxy — the harness that makes the CONCURRENT race reliable — produces
zero orphans, so this is a different defect. And the orphan is always a
DISCARDED connection, never the live one: `close()` works, `reconnect()`'s
discard is what sometimes fails.

## Mechanism

`_guardedConnection` builds the connection with
`ClientTransportConnection.viaStreams(guarded, outgoing)`, not `viaSocket`, so
package:http2 never owns the socket and `terminate()` can close the outgoing
sink and nothing more. `_discardConnection` calls `terminate()` and stops. The
`destroy` callback that would kill the socket is constructed three lines above
and wired only to a header-block violation.

Coherent, and not proven — see below.

## After

n/a — nothing shipped. The candidate fix was measured and reverted:

```
                     cycles  orphaned   which
before                 390      5       discarded (1 or 2)
with the destroy call  150      1       the LIVE connection (3)
```

## Canary

n/a. **That is the finding about the fix**: at ~1.3% there is no deterministic
witness to fail, so the canary protocol cannot be run at all. 1 in 150 against 5
in 390 is 0.67% against 1.28%, and 150 cycles expect two orphans if nothing
changed — the difference is noise. The one post-fix orphan was the live
connection, a mode absent from 390 prior cycles, which is either a second defect
or one the change introduced.

## Gate

`fvm dart analyze` on the package after the revert: clean, and `git diff` empty
against HEAD, so the revert is exact rather than approximate.

## Not fixed

All of it, deliberately, as lead B-25 with reason "risk". The rule this round
was tempted to break is the one that says no failing witness, no fix; the
temptation was strong because the mechanism reads convincingly and the owner has
seen the failure twice. A convincing story plus an unpowered number is exactly
the combination the canary rule exists to refuse.

What it would take is in B-25: either a deterministic reproduction of the sink
close failing to reach the peer, or ~2000 cycles an arm — about 75 minutes each
— to separate 1.3% from 0.65%.

## Links

Lens RPC-21 (first application in this journal; the shape it refines is
catalog U-15) · bench P-19 (new) · lead B-25 (new) · the concurrent sibling of
this defect is pinned by `concurrent_reconnect_test.dart` and predates the
journal.
