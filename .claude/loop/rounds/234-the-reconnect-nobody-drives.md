---
round: 234
verdict: FIXED
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-03
bench: P-13 — new
budget: probes 1/3, canaries 1/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record. Approved 7 of 7, with Q6 qualified in `## Not fixed`
commit: yes
---

# Round 234 — the reconnect nobody drives

## Target

B-06 — finish the websocket rescan round 233 left at a third, starting where
that round said to start: `websocket_caller_transport.dart`, 493 lines, unread,
the largest file and the home of `reconnect()`. Departed from `next` (lens
RPC-01, whose lead B-22 is with the owner) for the same reason 233 did: the owner
asked for the backlog and this is the priority transport.

The lens the reading landed on is RPC-03, not RPC-14.

## Hypothesis

`reconnect()` reads `_inner.lastIssuedStreamId` and every doc on that value says
it MUST be read before the outgoing transport is closed, because
`RpcChannelTransport.close()` calls `_idManager.reset()`. On the wrapper's own
reconnect that read is in time. On a drop the PEER started it cannot be: the
inner transport closes itself, and that self close is the only way the wrapper
learns it is disconnected at all.

## Before

```
  A control   reconnect on a live socket : idA=1 idB=3 disjoint
  B measured  peer died, health          : degraded "WebSocket connection is
                                           down. Reconnect is required."
  B measured  reconnect after peer death : idA=1 idB=1 COLLIDE
  B measured  late finishSending(idA)    : handlers ended 1 -> 2 (B ENDED)
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/ids_after_a_peer_started_reconnect.dart`
(bench `../probes/P-13-ids-after-a-peer-started-reconnect.md`).

The two arms differ by one event: who dropped the socket. `handlers ended` is a
baseline of 1, not 0 — losing connection 1 ends A's own handler, which is
correct. The second 1 -> 2 is the damage RPC-03 exists for: a dead call put a
real end-of-stream frame on the wire for a LIVE one and the server finished
serving it.

Isolated one hop lower, with nothing else differing at all:

```
  transport.createStream() x2 then close()
    lastIssuedStreamId    -1     <- "nothing issued yet"
```

## Mechanism

`close()` rewound the id cursor, and close is precisely the event that starts a
reconnect. The value exists only to survive a connection's death, and the death
deleted it — so `resumeStreamIdsAfter` was seeded with -1, the new manager
started at 1 again, and the two id spaces overlapped exactly as they did before
round 217. `_idsOnThisConnection` cannot help, and says so in its own comment:
B legitimately holds id 1, so a stale teardown for A's id 1 passes any check the
id alone can support.

**Sibling comparison named the outlier.** `RpcHttpCallerTransport` keeps its
manager across close; `RpcChannelTransport` was the only one that reset it.

Fixed at that point: `close()` now calls a new `RpcStreamIdManager.releaseAll()`,
which frees the active ids and keeps the cursor. `reset()` is untouched and
still rewinds, for anyone who wants a genuinely new id space.

## After

Same probe, same rig:

```
  A control   reconnect on a live socket : idA=1 idB=3 disjoint   <- unchanged
  B measured  reconnect after peer death : idA=1 idB=3 disjoint
  B measured  late finishSending(idA)    : handlers ended 1 -> 1 (B alive)
```

One fix, two reconnect paths: the websocket wrapper and core's
`RpcClientConnection` proxy, which reads its watermark in `_retire()` — i.e.
also after the transport has closed itself. Measured, not assumed: the proxy's
own witness is in the core suite below.

## Canary

`_idManager.releaseAll()` put back to `_idManager.reset()` in place. Four new
witnesses failed, none on a timeout:

```
  core   the cursor survives close     Expected: <3>      Actual: <-1>
  core   proxy, peer-started drop      Expected: not <1>  Actual: <1>
  ws     ids after a peer-started drop Expected: not <1>  Actual: <1>
  ws     the damage                    Expected: <1>      Actual: <2>
```

Under the same canary the three older WITNESS tests and both GUARD groups stayed
GREEN — which is the point of the round: they drive the reconnect the wrapper
starts, and that path was never broken. Restored, all green.

## Gate

`melos run analyze` SUCCESS (21 members + rpc_dart_wasm, no issues).
`melos run test:unit --no-select` SUCCESS across the workspace.
`melos run format:check` SUCCESS (`fvm dart format` first, 1 file).
`melos run license:check` 1174/1174, REUSE compliant.
Plus the neglected target this change is core enough to need:
`melos run test:web` (dart2js) 6/6.

`audit_frame_reassembly_linear_test` was reported failing at ratio 3.12 during
the run. It is the known wall-clock flake and it re-ran 4/4 at ratio 1.98-2.03
once the load average came off 13.7; in the failing run `dribble(N)` was 9677us
against 9529-9652us here — only the later half inflated, which is contention,
not scaling. Nothing in this round touches frame reassembly.

## Not fixed

**Q6 — the fix has one half, not two, and the half it keeps has no witness.**
`releaseAll()` still clears `_activeIds`, the other thing `reset()` did. Nothing
can witness that: ids are only ever generated from a live manager, so dropping
that clear too would go unnoticed by every test. This is L-04's shape — a guard
witnessed by an absence — and it is recorded rather than papered over.

**`RpcHttp2CallerTransport` was not measured.** It computes
`lastIssuedStreamId` as `_nextStreamId - 2` from a plain field, so it has no
manager to reset and cannot have this defect by construction; but no probe was
run against it, and "by construction" is reading, not measuring.

## Links

Lens `../lenses/RPC-03-stream-ids-restart-on-reconnect.md` — `applied: [234]`,
status `confirmed (round 234)`, third instance of the same shape.
Bench `../probes/P-13-ids-after-a-peer-started-reconnect.md` — new, validated by
its control.
Lead `../backlog/B-06-websocket-lead-list-is-stale.md` — CLOSED: the file 233
named as the place to start has now been read in full, and it held this.
Lesson `../lessons/L-06-the-path-the-owner-drives.md` — new.
Round `233-websocket-rescan-the-first-third.md` — named the file; this is what
was in it.
Round `217`/`224` — the same defect on the paths this side initiates.
