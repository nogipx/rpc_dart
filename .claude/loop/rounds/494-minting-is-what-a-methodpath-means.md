---
round: 494
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-05
bench: P-132 — new
commit: yes
---

# Round 494 — minting is what a methodPath means

## Target

B-103, tenth in the audit's rank and back to Dart after two native rounds.

Lens RPC-05 — something HELD that must be given back, at the right point of the
lifecycle. `_peerStreamIds` is held per stream and released on this side's
end-of-stream, and the release never covers the two ways it is acquired by
accident.

## Hypothesis

Every inbound frame on an id not currently in `_idsOnThisConnection` is recorded
as peer-minted, so a heartbeat pong and the late trailer of a cancelled call each
add a permanent entry — and each entry makes `_liveHere` true for a dead id.
Refuted if some other path removed them, or if neither source actually reaches
that listener.

## Before

```
                          peer ids
heartbeat 100ms for 3s    0 -> 29
no heartbeat, 3s idle     0 -> 0     <- control
50 cancelled calls        0 -> 50
50 completed calls        0 -> 0     <- control
```

Probe: `packages/transport/rpc_dart_websocket/.dart_tool/probe/b103_peer_ids_grow.dart`

Both sources confirmed at one entry per heartbeat interval and exactly one per
cancelled call, each against a paired control at zero.

**The set had to be made observable first.** `health()` delegated to the inner
transport, which cannot see either of the wrapper's own sets;
`idsOnThisConnection` and `peerStreamIds` are in the details now. Same move as
round 452's three http2 maps, same reason — a private set is unmeasurable, so the
invariant it carries is unfalsifiable.

## Mechanism

The recording test was `!_idsOnThisConnection.contains(id)`, which is "not ours
right now" rather than "theirs". Two ordinary things satisfy it:

- the app-level heartbeat mints through `_inner.createStream()` and releases
  through `_inner.releaseStreamId()`, bypassing the wrapper's set both ways, so
  every pong looked peer-minted;
- a cancelled call's `releaseStreamId` drops the id BEFORE the server's trailer
  arrives, so the trailer looked peer-minted.

## After

```
heartbeat 100ms for 3s    0 -> 0
50 cancelled calls        0 -> 0
```

One clause: `m.methodPath != null`. **A methodPath is what minting looks like** —
it is how a peer opens a call and what the responder pipeline itself keys on.
Neither a pong nor a trailer carries one.

Chosen over the sketch's three options. Removing the entry in `releaseStreamId`
does not work: the trailer arrives AFTER the release and would be re-added.
Minting the heartbeat id through the wrapper fixes only that half. Parity was
rejected by the field's own comment for a reason that still holds — it would
leave peer ids unguarded entirely.

## Canary

The `m.methodPath != null` clause removed — both WITNESSES fail with
`Expected: <0> / Actual: <30>` and `Expected: <0> / Actual: <50>`. Both CONTROLS
and the GUARD stay green.

**The guard is load-bearing here, more than usual**: after the fix every witness
reads ZERO, which is also what a transport that had stopped recording anything
would read. It drives a real reverse call through `RpcPeerEndpoint` and blocks
inside the handler, so the count is read while the peer's stream is open — `1`,
then `0` once answered. `peer_client_can_answer_a_reverse_call_test.dart`, which
exists because dropping every frame of every answer is what happens when this set
is wrong, is green too.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` 1956/1956, REUSE 3.3.

`license:check` went RED first, on `build/unit_test_assets/*` at the repo ROOT —
Flutter test artefacts left by round 493's device runs, from an invocation whose
cwd was the root rather than the example. Untracked, not part of the project,
removed. Worth naming because the failure looks like a licensing defect and is a
stray build directory.

## Not fixed

The heartbeat still mints and releases through `_inner`, bypassing the wrapper's
sets. It does not leak any more, and it never needed `_liveHere` — it sends
through `_inner` directly — but it is the same bypass B-130 is about, from the
other side.

The inverted-guard consequence is reasoned, not witnessed: each stale entry made
`_liveHere` true, which follows from that method's two-line body. Nothing here
drives a send on a dead id to see it admitted.

## Links

Lens RPC-05. Bench P-132 (new). Lead B-103 (closed). B-130 is the heartbeat's
other bypass. Round 452 is where the health-details idiom comes from.
