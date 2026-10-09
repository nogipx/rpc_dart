---
round: 527
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-03
bench: P-161 — new
commit: yes
severity: S2
---

# Round 527 — the guard the peer can defeat

## Target

B-131, taken in rank order: `deferFlowCredit`, `returnFlowCredit` and
`getMessagesForStream` go straight to the current `_inner` while the four send paths are
guarded.

Lens RPC-03. Its three prior instances — 217, 224, 234 — were all about ids THIS side
issues, where a watermark stops the collision. The lens's own text already names what is
left: *"a translation layer with its own id space, inbound direction included"*. This is
the first round to look in that direction.

## Hypothesis

The three forwards are unguarded, so an operation issued for an id from the previous
connection acts on the current one — and applying `_liveHere`, as the lead asks, fixes it.

## Before

```
  arm                                  stale trailer   credit frames
  peer id, reconnect, peer REUSES it   DELIVERED       1
  peer id, reconnect, not reused       dropped         1
  own id, reconnect (space resumed)    dropped         1
  CONTROL peer id, no reconnect        DELIVERED       1
```

Bench `../probes/P-161-does-a-stale-id-reach-the-new-socket.md`.

Two findings, and the lead names only the first.

**The flow-credit pair is unguarded** — column 2 is `1` on every row, including the two
where the guarded `sendMetadata` was correctly dropped. A credit returned for an id live
on neither set grants a window nothing consumed and credits a pool nothing drew from.

**The guard the lead wants applied does not cover the case the lead is about.** Row 1
against row 2: the same stale id, the same call, differing only in whether the peer
reopened the number. `_liveHere` is membership, the reconnect clears both sets, and the
peer's first frame on the reused number puts it straight back — so a stale teardown is
DELIVERED to the call that now holds it.

The controls are row 4 (no reconnect, so `dropped` is a guard and not a dead pipe) and
row 3 (the wrapper resumes its own cursor, so its own ids cannot collide and the guard
holds).

## Mechanism

Ids this side mints are made disjoint across a reconnect by `resumeStreamIdsAfter`, so
membership is enough for them. The peer numbers its own streams and restarts at the bottom
on every socket, and the interface carries a bare `int` — nothing in an operation says
which connection its id came from. `_liveHere` cannot distinguish, and no check placed
after the collision can.

## After

```
  arm                                  stale trailer   credit frames
  peer id, reconnect, peer REUSES it   DELIVERED       1
  peer id, reconnect, not reused       dropped         0
  own id, reconnect (space resumed)    dropped         0
  CONTROL peer id, no reconnect        DELIVERED       1
```

`deferFlowCredit` and `returnFlowCredit` now carry the same `_liveHere` guard as the
sends. Row 1 is unchanged on purpose — it is not this fix's to close, and a witness
asserting `0` there would be asserting a fix nobody made.

`getMessagesForStream` is left unguarded, which is a third finding about the lead: one of
its three named methods needs no guard. A subscription is taken at call setup, so a stale
id can only reach it from a call set up on a connection that no longer exists, and the
inner transport already answers that with a controller nobody feeds. The one case a guard
would have to catch is the reuse case membership cannot see — and failing closed on a
DELIVERY path turns a wasted subscription into a handler that never receives a request.

## Canary

`returnFlowCredit`'s guard removed in place: WITNESS fails `Expected: <0> Actual: <1>`,
with its own reason line. CONTROL and GUARD still pass, which is what says the witness is
reading the guard rather than the rig.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. The websocket package
alone: 209 passed.

## Not fixed

**Row 1, and it is the severe one.** A stale teardown for a reused peer id terminates a
different live call — the same harm `_idsOnThisConnection` was built to prevent, in the
direction where its remedy is unavailable. Filed as B-199 with the measurement.

Deliberately not attempted here. RPC-03 round 218 already measured that a generation
ledger keyed on the id CANNOT work once the numbers collide, and the lens's remaining
answer — translating peer ids into a space of the wrapper's own, rewriting inbound and
outbound — is a design change with a per-frame cost in both directions. That is the
owner's call, not a round's.

**No responder pipeline was driven.** The stale calls are made directly, so the round
measures the transport's contract and not the odds of a real consumption tail outliving a
reconnect. A round wanting that would need a peer-mode client-stream handler still
draining when the socket drops.

**The harm downstream of a spurious grant is bounded but unmeasured.** A peer clamps an
incoming grant at its own window, so an over-statement costs at most one window per reused
stream; nothing here read the peer's credit to confirm the bound holds on this path.

## Links

Lens RPC-03 (extended: the inbound direction, first swept here). Bench P-161 (new). Lead
B-131 closed. New lead B-199. Round 218 is why the obvious fix for B-199 is known not to
work.
