---
round: 295
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: none
commit: yes
---

# Round 295 — the invariant, not the evidence

## Target

`responder_pipeline.dart`, 308 doc lines — top of RPC-23's ranking, and the file
round 294 refused to take until the lens said how to judge INTERNAL code. That
question is settled first, in the lens, and then applied.

## Hypothesis

RPC-23's third question — *could a caller choose without it* — has no meaning
for a private field. There is no caller. Applying the lens unchanged would
either preserve everything (no caller, so nothing is unnecessary) or cut by
taste.

## Before

```
responder_pipeline.dart   308 doc lines
core/lib/src total       4319
```

Four private members carried measured essays: the stream ceiling cache (16
lines), the pre-method byte budget (28), the half-open reclaim (21), the
handler-slot wrapper (14).

## Mechanism

The lens gains the internal variant, and it is a different question rather than
a softer one:

> A private field has no caller; it has a maintainer about to change it. Ask
> *what would someone editing this break without knowing?* The keeper is the
> INVARIANT — why the charge point is dispatch and not entry, why the cursor
> must survive close, why this counter is per connection — because that is what
> a plausible edit destroys silently.
>
> The measurement that PROVED the invariant is still journal. "37 handlers
> against a ceiling of 4" belongs in the round; "charged at dispatch, released
> when the handler finishes, because a stream can die before its work does"
> belongs in the code.

## After

```
responder_pipeline.dart   270 doc lines   (-38)
core/lib/src total       4281             (-149 since 293's baseline of 4430)
```

Kept, in each case because an edit that ignored it would silently reintroduce a
measured defect:

- charged at DISPATCH, not entry — otherwise a simultaneous burst walks through
- wrapped around the whole interceptor chain, not the handler — an interceptor
  parked either side of `next()` is work outside the handler
- the pre-method budget is per CONNECTION — per stream, and inventing ids buys
  more budget
- the reclaim is armed once and cancelled at dispatch — so a long-running
  handler is never affected, and one request frame parks the same state anyway

Cut: 500 concurrent streams accepted against a ceiling of 3, 250.7 MiB pushed
for +495.2 MiB RSS, eight metadata-only frames, 30 http2 calls against a ceiling
of 3. All of it lives in rounds 205, 213-215 and 236, dated and aged by `stale`.

## Canary

`public_member_api_docs` covers the public members; these four are private, so
the analyzer cannot witness their comments at all. What it does witness is that
the code around them still compiles and the suite still passes — which is the
honest limit of a doc round's canary, and worth stating rather than implying a
stronger check.

## Gate

`melos run analyze` — 0 errors workspace-wide. `rpc_dart` suite green.

## Not fixed

The queue: `channel_transport.dart` 303, `base_processor.dart` 227,
`context.dart` 176, `rate_limiter.dart` 161, `security_policy.dart` 151.

`responder_pipeline.dart` is not finished either — 270 lines remain, and the
ones left are mostly at the top of methods where the invariant and the narrative
are interleaved sentence by sentence rather than in separate paragraphs. Those
need reading in full, not pattern-matching.

**The pace is wrong and the owner said so during this round.** 149 doc lines
across rounds 293-295, against a baseline of 4430 — at four comment blocks per
round the mandate does not finish. The cause is method, not scale: I read and
judged one block at a time, which is right for deriving the lens and wasteful
once it exists.

From 296 the unit is a FILE, not a block: read it whole, cut every comment in
one pass, one gate, one commit. The ranking already says the order, and the
lens now answers both reader cases, so nothing needs re-deriving per block.

## Links

RPC-23 (`applied:` gains 295), extended with the internal-reader question — the
first time this mandate changed a lens rather than only applying one.
