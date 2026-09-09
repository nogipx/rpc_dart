---
round: 229
verdict: FIXED
packages: [rpc_dart]
lens: RPC-01
bench: P-12 — new
budget: probes 0/3, canaries 0/3
review: self — the session forbids the Agent tool unless the user asks; the `loop.py review` prompt was answered against the record, the bench and the canary. Approved 10 of 10
commit: yes
---

# Round 229 — a zero grant is not silence

## Target

`next` named RPC-01 again, which round 228 had just swept. Took the same lens at
an open lead in its own family instead: **B-05**, "a window-credit failure is
silent — zero credit is read as 'the peer does not participate'".

## Hypothesis

If a lost or zero grant is indistinguishable from a peer that predates flow
control, the sender degrades to unbounded against a peer that is in fact
participating.

## Before

Rule one found it before any probe did. `_fcNotePeerGranted`'s own doc:

> Records that the peer does flow control at a level, whatever the grant turns
> out to be worth. **A grant frame at all is the proof; its value is not.**

Both call sites gated it on `parsed > 0`. So a peer whose first grant is ZERO —
a legitimate "I have no room right now" — was never recorded as participating.
A sender parked on the seeded initial window then armed the legacy grace, which
expired, assumed a pre-flow-control peer, and set that level's credit to null.

Measured through a 64 KiB connection window with a 16 KiB initial send window,
the peer sending exactly one grant frame:

```
  peer grants 1     20 KiB accepted     <- control, bounded
  peer grants 0    800 KiB accepted     <- 12.5x the window
```

The sender flooded a peer that had just said it had no room.

## Mechanism

The value of a grant answers "how much may I send". Whether a grant ARRIVED
answers a different question — "does this peer speak flow control at all" — and
only the second one may switch the mechanism off. Conflating them made zero, the
one value that means *stop*, read as *this peer has never heard of stopping*.

Fixed at both levels: participation is proved by a well-formed grant, the credit
is still gated on `> 0`, so "a peer sending garbage credit must not move our
window" is untouched.

## After

```
  peer grants 1     20 KiB accepted     <- control, unchanged
  peer grants 0     16 KiB accepted     <- exactly the seeded initial window
```

16 KiB is the seed and nothing more: the sender spends what it was given before
the peer spoke, then parks, because the peer said zero.

## Canary

Fix switched off in place (`parsed != null` back to `parsed != null && parsed >
0`):

```
WITNESS: a zero grant is participation, not silence
  Expected: a value less than or equal to <65536>
    Actual: <819200>
  the peer granted 0 -- it has no room -- and the sender pushed 800 KiB
  through a 64 KiB window
```

A real number, not a timeout. **Both guards stayed green under the canary**, so
the witness isolates this defect rather than re-checking the seeding work of
earlier rounds.

The second guard is the load-bearing one: *a peer that never grants is still
allowed to degrade*. The legacy path exists because a genuinely old peer would
otherwise park forever, and a fix that counted silence as participation would
have reintroduced that hang while passing the witness.

## Gate

```
melos run analyze                No issues found!   21 packages + rpc_dart_wasm
melos run format:check           0 changed          21 packages + rpc_dart_wasm
melos run test:unit --no-select  All tests passed   14 packages
```

`analyze` failed once first on an `unnecessary_import` in the new test, fixed
and re-run green.

## Not fixed

**The other half of B-05 stands: the degradation is unlogged.** When the grace
expires and a level is assumed legacy, nothing is written anywhere — no warning,
no metric. An operator whose peer's grants are genuinely being dropped sees an
unbounded sender and no reason for it. That remains a diagnostic, and the
config's bar rules diagnostics out as a round's product, so it is recorded here
rather than shipped.

**`_fcSendGrant` swallows a send failure** with the comment "a lost grant only
matters if the connection is still alive, and a throw here means it is not". Not
re-measured this round. It is the same family as this defect — a grant that never
arrives — and U-01 says a comment justifying deliberateness is a lead, not a
closed door.

## Links

Lead `../backlog/B-05-isolate-null-credit-silent.md` — closed by this round,
except the logging half.
Bench `../probes/P-12-zero-grant-reads-as-legacy.md` — new.
Lens `../lenses/RPC-01-flow-control-credit-on-skip.md` — `applied: [229]`.
Round `228-the-branch-206-did-not-cover.md` — the previous sweep of this lens.
