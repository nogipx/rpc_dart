---
file: packages/core/rpc_dart/.dart_tool/probe/b120_token_and_context_cost.dart
round: 511
commit: 231f986c
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
status: valid
---

# P-149 — what do the per-call id draws cost a call?

## Why it exists

B-120 asks for a profiler. A profiler is not needed to answer what the lead is
really asking — whether either candidate is worth changing — and a profile would
have been harder to act on than the two numbers this produces.

The rig times the two candidates directly, times a whole unary call, and then
**ablates the generator in place and re-times the call**. The last step is what
makes the finding trustworthy: a microbench of `Random.secure()` invites the
objection that it is not measuring what a call actually pays.

## The harness

Three parts.

1. `_uniqueToken`'s exact shape — three 32-bit draws plus a monotonic counter —
   timed against `Random.secure()` and a plain `Random()`.
2. A 6-link `RpcContext` chain, the middle of the 5-7 the lead names.
3. A whole unary call over the in-memory pair.

Then `_strongRng` is forced to `null` in `context.dart`, which makes every token
come from `_fallbackRng` — a path the library already takes on node — and the call
is timed again.

## The numbers (round 511)

```
token, Random.secure()      30.98 - 37.82 us/token
token, plain Random()        0.158 - 0.166 us/token

a whole unary call, secure RNG      88.69 / 101.21 / 101.09 / 97.53 us
a whole unary call, fallback RNG    52.77 /  58.01 /  57.51        us
```

**About 40 us of every ~97 us unary call is OS entropy for two correlation ids.**
The two sets do not overlap and the gap is ~2x, far outside the ~15% run-to-run
spread seen elsewhere in this repo.

## Measures

Microseconds per call, end to end, with the generator as the only thing varied.

The token microbench is supporting evidence, not the finding: 196x between the two
generators explains the end-to-end gap but is not what establishes it.

## Control

**The end-to-end arm IS the control on the microbench.** Two tokens at ~31 us each
predicts ~62 us of saving; the measured saving is ~40 us. The prediction being in the
right range but not exact is the useful part — it says the microbench is measuring
the right thing without being a substitute for the real path.

**The context-chain number is explicitly NOT a share of anything** and the probe says
so in its own output. Six `with*` links with two headers is a synthetic worst case,
not what a call builds, and quoting it as "37.8% of a call" — as an earlier draft of
this probe did — double-counts against a call figure it was never measured inside.

## What it establishes, and what it does not

Establishes: `Random.secure().nextInt()` reaches the system entropy source on every
call, a unary call mints two tokens, and that is ~40% of the call on the in-memory
pair.

Does NOT establish that this matters on a real transport. On a network link the
per-call cost is dominated by the wire; this is visible on in-memory and isolate,
which is exactly what the lead predicted.

Does NOT measure the context copies as a share of a real call, and does not measure
`withAdditionalHeaders` re-running the header regex, or `forClientRequest`'s two
regexes — the other halves of the lead. The 6-link chain says only that the chain is
not free.

## Reading

rpc_dart — **ablates the generator in place and re-times the whole call**,
because a microbench of `Random.secure()` invites the objection that it is not
measuring what a call actually pays. The microbench is supporting evidence
only: two tokens at ~31 us predicts ~62 us of saving where ~40 us is measured,
and being in the right range without being exact is what says it measures the
right thing without substituting for the real path. **One number in it is
explicitly NOT a share of anything** and the probe prints that warning itself
— the 6-link context chain is a synthetic worst case, and an earlier draft
quoted it as "37.8% of a call", double-counting against a figure it was never
measured inside.
