---
round: 564
verdict: FIXED
packages: [rpc_dart_http2]
lens: RPC-17
bench: none — the observable added here IS the instrument, and the canary is what measured it
budget: probes 0/5, canaries 2/5
commit: yes
release: none
---

# Round 564 — the unreported map, and a vacuous zero

## Target

B-184's remaining item, the `_halfClosedLocal` leak, after round 563 recorded the breadth sweep: of
three sites that add to that set, only `sendMessage`'s add sits after an await, so only it can be
re-added behind a release.

The round set out to witness that race and did not. What it found instead is why nobody had: **the map
was the one per-stream map `health()` did not report**, and the shapes available to a test never fill
it.

Lens RPC-17: a limit, or a ledger, whose growth nothing watches.

## Hypothesis

A release landing during a successful send leaves one entry per stream. Observable by counting the set
after completed calls.

## Before

```
health().details, per-stream maps reported:
  activeStreams  pendingSubscriptions  pendingParsers
  fcOutstanding  outgoingPumps         streamControllers
  halfClosedLocal   -- ABSENT
```

Every per-stream map is reported *because* growth in one is the symptom of an entry added and never
removed — the reasoning `flowControlConnectionCredit`'s own doc gives for being readable at all. The map
with the known re-add-after-await is the one that was invisible.

## Mechanism

`'halfClosedLocal': _halfClosedLocal.length` joins its siblings, so the leak class has an observable at
all. Plus a guard asserting every reported per-stream map is back to 0 after completed unary and
server-stream calls, five times each.

## After

The guard passes, and then the canary says what it is worth.

## Canary

**Two, and both PASSED — which is the round's actual result.**

```
A. `_halfClosedLocal.remove` dropped from `releaseStreamId`      test still passes
B. dropped from the inline release as well                        test still passes
```

**So these shapes never populate the map.** Unary and server-stream carry their half-close some other
way — neither reaches `sendMessage(endStream: true)` nor `finishSending` on this transport — and the
`halfClosedLocal == 0` row is a VACUOUS zero that guards nothing.

That is the trap `methods/canary.md` names: an arm that cannot see the defect reads exactly like a pass.
Without the second canary the test would have shipped as a guard against a leak it cannot observe, and
the lead would have read as covered.

The row stays for its `containsKey` half — the exposure is what was missing — and the test says in its
own header that the zero is vacuous for these shapes.

## Gate

```
melos run analyze               SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select SUCCESS   15 packages
melos run format:check          SUCCESS   0 changed
melos run license:check         SUCCESS   REUSE compliant
```

## Not fixed

**The guard was NOT applied, for the second round running, and now for a better reason.** Round 563
declined it for want of a witness; this round established that the witness needs a shape that fills the
map, and the two shapes a test can drive easily do not. `_activeStreams.containsKey(streamId)` on the
re-add is still the fix, and it still has no failing arm.

**What the next round needs is named**: a call that reaches `sendMessage(endStream: true)` or
`finishSending` on this transport — a client-stream or bidi upload — with a release driven into the
window while the send is parked. The pump can be parked by a server that stops reading, which
`P-183`'s rig already does at the pump level.

**The other six rows are unverified as guards too.** Canary A and B only ablated `halfClosedLocal`;
whether the test would catch a leak in `pendingParsers` or `outgoingPumps` is unmeasured, so the
invariant is asserted rather than witnessed for all seven.

## Links

Lead `../backlog/B-184-http2-send-message-races-after-its-await.md` — the item stays open, with the rig
it needs now specified.
Round `563-the-bound-the-comment-described-and-did-not-provide.md` — where the breadth sweep was
recorded.
Bench `../probes/P-183-what-reaches-the-wire-when-a-parked-send-meets-a-half-close.md` — parks a pump,
which is half the rig the next round needs.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [564]`.
