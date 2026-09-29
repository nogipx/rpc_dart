---
round: 511
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-17
bench: P-149 — new
commit: yes
---

# Round 511 — forty per cent of a call is entropy

## Target

The per-call id and context cost — twenty-seventh in the audit's rank, the second
COST-class lead of the run.

Lens RPC-17, in round 507's reading: ask what the work is FOR. These ids are for
correlating log lines. They are drawn from the system entropy source.

## Hypothesis

`requestId` is three `Random.secure().nextInt` calls, the server mints a trace id
too, and the context maps are copied five to seven times per call.

## Before

```
token, Random.secure()      30.98 - 37.82 us/token
token, plain Random()        0.158 - 0.166 us/token

a whole unary call, secure RNG    88.69 / 101.21 / 101.09 / 97.53 us
a whole unary call, fallback RNG  52.77 /  58.01 /  57.51        us
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b120_token_and_context_cost.dart`

**CONFIRMED, and larger than the lead suggests: about 40 us of every ~97 us unary
call is OS entropy for two correlation ids.** The two sets do not overlap and the gap
is ~2x, far outside the ~15% run-to-run spread this repo shows elsewhere.

**The end-to-end ablation is what makes it trustworthy.** A microbench of
`Random.secure()` invites the objection that it is not measuring what a call pays, so
`_strongRng` was forced to `null` in place — which makes every token come from
`_fallbackRng`, a path the library already takes on node — and the call re-timed.

## Mechanism

An earlier round already worked on this and its comment explains the shape:

> THREE draws of 32 bits, not twelve of 8: the same 96 bits from the same generator,
> in a quarter of the time. `Random.secure().nextInt()` reaches the system entropy
> source on EVERY call, and a unary call spends three tokens, so the per-byte form
> cost the majority of an RPC's total time.

So the count was cut 12 → 3 and the generator hoisted to a static. What was not
revisited is whether it should be a secure generator at all. Three syscalls is
cheaper than twelve; it is still three syscalls, twice per call.

## After

Nothing. `lib/` is untouched — this round measures and defers.

## Canary

n/a for a fix. The ablation described above is the equivalent and is what the
before-table's second half is.

## Gate

Not run: nothing in `lib/` or `test/` changed.

## Not fixed

**The change is one line and the codebase has already written its own justification
for it.** `_strongRng`'s doc says these ids are *"correlation in logs and on the
wire, never secrets or capability tokens"*, and records that **on node every token
already comes from the non-cryptographic generator** and that this is acceptable. So
using `_fallbackRng` everywhere is not a new security posture — it is extending one
the library already ships and documents on one platform.

That is a strong argument, and it is still not a round's call. It changes what a VM
or Chrome deployment gets today, and the precedent set by B-111 and B-116 this run is
that a documented security posture is decided by the owner with the number in hand.
The number is ~40% of a unary call on the in-memory pair.

Three options, with what each costs:

1. **Use `_fallbackRng` for these ids everywhere.** ~40 us per call back. Ids become
   predictable on every platform rather than on node alone. Needs a CHANGELOG line
   aimed at anyone who assumed otherwise despite the doc.
2. **Seed a non-cryptographic generator from ONE secure draw at startup.** Same
   saving, and the sequence is unguessable without knowing the seed. More code than
   option 1 for a property the doc says is not required.
3. **Keep it.** The cost is invisible on any network transport — it is visible on
   in-memory and isolate, which is what the lead predicted.

**The context half is barely measured and the record says so.** A 6-link chain costs
~35 us, but that is a synthetic worst case rather than what a call builds, and
quoting it as a share of a call — as an earlier draft of the probe did — double-counts
against a figure it was never measured inside. `withAdditionalHeaders` re-running the
header regex and `forClientRequest`'s two regexes were not measured at all.

## Links

Lens RPC-17. Bench P-149 (new). Lead B-120 (awaiting owner). The earlier round that
cut the draws 12 → 3 is the one whose reasoning this extends.
