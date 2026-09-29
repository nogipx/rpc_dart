---
status: decided by owner (round 540)
round: 511
commit: 231f986c
release: changelog
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/core/metadata.dart]
probe: P-149
reason: "CONFIRMED and larger than filed: ~40 us of every ~97 us unary call is OS entropy for two correlation ids, established end-to-end by ablating the generator. The fix is one line and the codebase already documents these ids as 'never secrets' — but it changes what a VM deployment gets today, so it is the owner's by the precedent B-111 and B-116 set"
---

# B-120 — each call copies both context maps five to seven times and draws 12 bytes of OS entropy

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Every `with*` rebuilds `_headers` and `_values` via `Map.from`, `withAdditionalHeaders` re-runs the header regex over all headers, the pipeline chains 5-7 of them per call; `requestId` is three `Random.secure().nextInt` calls, the server mints a trace id too; `forClientRequest` runs two regexes per call.

## The shape

`packages/core/rpc_dart/lib/src/contracts/context.dart` constructor (`Map.from(headers)`, `Map.from(values)`),
`_uniqueToken`, `_sanitizeHeaders`; `caller_pipeline.dart:134-178`;
`metadata.dart:117-127, 471-484`.

## Why it matters

Allocation and syscalls on the per-call path; visible on in-memory and isolate
where the transport itself is cheap.

## Witness a round would build

Unary calls/s over the in-memory pair with a profiler; share of time in
`RpcContext._` and `_uniqueToken`.

## Fix sketch

Persistent/structural sharing for headers and values, validate once, a
non-cryptographic id generator seeded once (ids are correlation, not secrets).

## Outcome (round 511) — confirmed, and bigger than filed

```
token, Random.secure()      30.98 - 37.82 us/token
token, plain Random()        0.158 - 0.166 us/token

a whole unary call, secure RNG    88.69 / 101.21 / 101.09 / 97.53 us
a whole unary call, fallback RNG  52.77 /  58.01 /  57.51        us
```

**About 40 us of every ~97 us unary call is OS entropy for two correlation ids.** The
sets do not overlap; the gap is ~2x against a ~15% run-to-run spread.

Established END TO END by forcing `_strongRng` to null — which makes every token come
from `_fallbackRng`, the path the library already takes on node — not by a microbench
alone, because a microbench of `Random.secure()` invites the objection that it is not
measuring what a call pays.

An earlier round already cut the draws 12 → 3 and hoisted the generator to a static.
What it did not revisit is whether the generator should be secure at all.

## Owner decision

**DECIDED in the round-540 review: cut the NUMBER of draws first, and leave the generator
alone until that is done.** None of the three options above was taken.

The reasoning: a call draws for TWO correlation ids, and one of them is minted by the
responder only to be replaced. If that draw is unnecessary, removing it takes half the ~40 us
while keeping `Random.secure()` — so the security posture never has to be traded at all, and
whatever remains afterwards is a smaller number to decide about.

**The constraint that makes this harder than it reads.** The two ids are not interchangeable.
`requestId` is minted by the caller and travels on the wire; the responder's trace id is minted
locally, and the round has to establish WHY it is minted before it is replaced — whether
something reads it in the window between, in a log line, in a metric, or in the
opentelemetry package, which is a separate package the lead's `paths:` do not name. Removing a
draw whose value is read by something else is a silent behaviour change in a diagnostic, and
diagnostics are where a missing value is least likely to be noticed.

So the round's first arm is not a benchmark. It is: how many secure draws does one unary call
make, where does each land, and is any of them dead on arrival. P-149 already ablates the
generator end-to-end, so it can price whatever the sweep removes.

**The three options below stay on the record and are NOT closed** — they are the decision that
comes after this one, against a smaller number.

**The change is one line, and the codebase has already written its own justification
for it.** `_strongRng`'s doc says these ids are *"correlation in logs and on the wire,
never secrets or capability tokens"*, and records that **on node every token already
comes from the non-cryptographic generator**, calling that acceptable. Using
`_fallbackRng` everywhere extends a posture the library already ships and documents
rather than inventing one.

It is still not a round's call: it changes what a VM or Chrome deployment gets today,
and B-111 and B-116 set the precedent that a documented security posture is decided
here, with the number in hand.

1. **`_fallbackRng` for these ids everywhere.** ~40 us per call back. Ids become
   predictable on every platform rather than on node alone. Wants a CHANGELOG line
   aimed at anyone who assumed otherwise despite the doc.
2. **Seed a non-cryptographic generator from ONE secure draw at startup.** Same
   saving; the sequence is unguessable without the seed. More code than option 1, for
   a property the doc says is not required.
3. **Keep it.** The cost is invisible on any network transport. It is visible on
   in-memory and isolate — which is exactly what this lead predicted.

## Still open, barely measured

**The context half.** A 6-link `with*` chain costs ~35 us, but that is a synthetic
worst case rather than what a call builds, so it is not a share of a call and the
probe says so in its own output. `withAdditionalHeaders` re-running the header regex
over all headers, and `forClientRequest`'s two regexes, were not measured at all.

Whoever takes that half should measure the chain a REAL call builds, not a
constructed one — the mistake an earlier draft of P-149 made was quoting the
synthetic number as "37.8% of a call".
