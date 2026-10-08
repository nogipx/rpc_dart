# Lens set — rpc_dart

What a lens is and how it links to the rest — [../LOOP.md](../LOOP.md). The
field format — `../../skills/evidence-loop/specs/lens.md`.

**The order below is the rank**, re-derived in the curate pass after round 220:
a sweep whose paths have moved comes first (it is due a re-measurement), then
the ones that have produced findings recently, then the rest. A lens is never
deleted — no findings is a result too, and a deleted lens gets reinvented.

## Due a re-measurement

**RPC-02, added by the curate pass after round 348, by the same classification
the note below describes — and this time it came out the other way.**

`stale` reports RPC-02, RPC-09, RPC-14 and RPC-19 as aged, 25 to 29 files each.
One `git log` per lens along its own paths separates them:

```
RPC-02   4 commits since 1ab3e26e   8a28f1bf, 4527416a  <- BOTH in its territory
RPC-09   8 commits since 9bb632e0   none in its territory
RPC-14   8 commits since 34f0b039   none in its territory
RPC-19  10 commits since 4b5727a5   none in its territory
```

RPC-02 is *a refusal survives its own policy*, and rounds 340 and 342 changed
refusal behaviour on the transport the lens was swept on: 340 made http2 validate
OUTBOUND metadata against the policy, which is the lens's own rule applied in the
direction it had not been; 342 added the 256-violation backstop, which changes
what a refusal costs a connection. Neither was measured against this lens. **It
ages back in on behaviour, not churn.**

The other three do not. Their windows are dominated by round 337's 158 log
guards and the two lint-floor rounds; the behavioural commits inside them —
`355f773c` (answering a failed unary request stream), `13fc66c3` (an inbound
size cap), `fbe8f744` (one caller-stream bridge) — are not about a deadline
below a write, a timeout abandoning work, or a flag with two lifecycle meanings.

> **Round 347 met RPC-14's shape in a dependency and it is worth recording here
> rather than ageing the lens for it**: `finish().timeout()` abandons the AWAIT,
> not the work, which is exactly what the lens is about — but the code doing it
> is `package:http2`, outside every path the lens names. Filed as B-35.

The note the pass after round 327 wrote, which is the method above:

`stale` reports RPC-09, RPC-14 and RPC-19 as aged, three to five rounds after
each was swept clean (322, 323, 324). Classifying the commits along each lens's
own paths:

```
RPC-09   1 commit since 9bb632e0   f70775cb
RPC-14   1 commit since 34f0b039   f70775cb, 1ab3e26e
RPC-19   1 commit since 4b5727a5   1ab3e26e
```

Both are the lint-floor rounds (325, 326), and both are **mechanical**: typed
`onError` closures, `Future<void>.delayed`, `StreamSubscription<void>`, import
order, tearoffs. 161 files, and every test count in the workspace unchanged
across them. Nothing these lenses are about moved.

> **A repo-wide mechanical sweep ages the whole journal at once.** `stale`
> computes from path churn, so it cannot tell a type argument from a logic
> change, and after rounds 325-326 it reports **30 of 31 benches, 28 of 34
> negatives and 3 of 4 sweeps** as aged. Round 319 hit the inverse of this and
> was right to check: there, 19 of 31 commits WERE behavioural. The rule is that
> the classification is cheap — one `git log` per record — and skipping it in
> either direction is what costs a round.

So the queue is empty by measurement. What ages back in is whatever the next
BEHAVIOURAL commit touches.

## Imported from private memory, never applied here — take these first

Added in the curate pass after round 234, which measured the actual seam between
the two corpora: `checked/` had imported the pre-201 NEGATIVES (C-02 round 46,
C-04 round 106 and the rest), but the pre-201 defect SHAPES had no lens, so
`loop.py next` could not route to them and `stale` could not age them. Greps for
their own numbers returned nothing in the loop: `CONTINUATION`, `756 MiB`,
`check before await`, `pre-ready`, all zero hits.

- **[RPC-20](RPC-20-the-window-before-the-first-listener.md)** confirmed (round 373) — The window before the first listener
- **[RPC-21](RPC-21-drive-the-lifecycle-twice.md)** confirmed (round 732) — Drive the lifecycle twice

## The refactor mandate — derived after round 292

The set above is entirely defect-shaped: every lens asks "what is broken". The
owner's refactor mandate asks a different question, and without a lens for it a
round reaches for the worst file it can see instead of auditing the whole
surface. These three are that lens — one per clause of the mandate: the doc
comments (RPC-23), the boundary and the API (RPC-24), the code and its
abstractions (RPC-25).

- **[RPC-23](RPC-23-the-narrative-beside-the-code.md)** confirmed (round 586) — The narrative beside the code
- **[RPC-24](RPC-24-public-by-omission.md)** confirmed (round 590) — Public by omission
- **[RPC-25](RPC-25-the-same-abstraction-four-times.md)** confirmed (round 587) — The same abstraction, four times

## The gate itself

`loop.py yield` after round 327: **RPC-26 is 2 rounds, 2 FIXED** — the only lens
applied more than once with every application paying. Ranked here rather than
under "Productive lately" because its remaining surface is known and finite: 20
of 22 packages have never had the count taken, and two of those are deliberate
exclusions with reasons.

- **[RPC-26](RPC-26-the-gate-floor-nobody-chose.md)** confirmed (round 325) — The gate's floor is a default nobody chose

## Productive lately

- **[RPC-22](RPC-22-the-refusal-path-is-reachable-by-anyone.md)** confirmed (round 397) — The path a peer reaches without being accepted
- **[RPC-18](RPC-18-dependency-buffers-below-your-limits.md)** confirmed (round 237) — The dependency buffers below every limit you own
- **[RPC-17](RPC-17-limit-fires-after-residency.md)** confirmed (round 720) — A limit that fires after the bytes are resident
- **[RPC-16](RPC-16-check-before-await.md)** confirmed (round 235) — The guard read before the await
- **[RPC-01](RPC-01-flow-control-credit-on-skip.md)** confirmed (round 558) — Flow-control credit on the skip path
- **[RPC-04](RPC-04-capability-hidden-by-wrapper.md)** confirmed (round 488) — Transport capabilities hidden by a wrapper
- **[RPC-03](RPC-03-stream-ids-restart-on-reconnect.md)** confirmed (round 661) — Stream ids that outlive a reconnect
- **[RPC-15](RPC-15-remeasure-own-record.md)** confirmed (round 730) — Re-measure the loop's own record

## Swept and fresh

- **[RPC-19](RPC-19-one-flag-two-lifecycle-meanings.md)** confirmed (round 748) — One flag, two lifecycle meanings

- **[RPC-14](RPC-14-timeout-abandons-work.md)** confirmed (round 499) — A timeout abandons the wait, not the work
- **[RPC-13](RPC-13-unhandled-async-error.md)** confirmed (round 747) — An unhandled async error is fatal to the isolate
- **[RPC-09](RPC-09-deadline-below-write.md)** swept here (round 743, a94aca2c) — A call deadline that sits below the write
- **[RPC-02](RPC-02-refusal-trailer-violates-policy.md)** swept here (round 734, a94aca2c) — A refusal trailer that violates the policy it enforced
- **[RPC-05](RPC-05-concurrency-limit-charge-point.md)** confirmed (round 494) — Where a concurrency limit is charged
- **[RPC-11](RPC-11-package-outside-workspace.md)** confirmed (round 220) — A package outside the workspace
- **[RPC-07](RPC-07-web-as-separate-runtime.md)** confirmed (round 428) — The web as a separate runtime
- **[RPC-08](RPC-08-policy-field-single-transport.md)** confirmed (round 584) — A policy field checked on one transport

- **[RPC-06](RPC-06-native-plugin-layers.md)** confirmed (round 365) — The plugin's native layers
- **[RPC-10](RPC-10-shared-layer-blast-radius.md)** confirmed (round 150, off-journal) — A shared layer does not reach every neighbour

## Nobody has taken these, and why

Empty. Both former entries — RPC-06 and RPC-10 — have since been applied, and
the reasons given for not taking them turned out to be about the ORIGINAL
framing rather than the lens: RPC-06's toolchains did eventually exist, and
RPC-10 became a defect-finder the moment the question was asked in the other
direction. **A "nobody takes this" note ages like any other record.** Both sat
here stale for several rounds after the lens had paid.

## Retracted

- **[RPC-12](RPC-12-cancel-into-request-stream.md)** retracted (round 204) — Cancellation delivered into the handler's request stream

Sweeps marked «off-journal» have nothing to age against: `stale` always shows
them as needing a re-measurement. That is correct — the code has changed since,
and the sha of that sweep is unknown.
