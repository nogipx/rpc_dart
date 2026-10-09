---
round: 551
verdict: DEFERRED
packages: [rpc_dart]
lens: RPC-15
bench: P-179 — new
budget: probes 1/5, canaries 0/5
commit: yes
release: none
severity: S3
---

# Round 551 — the draws were already cut

## Target

The owner's decision on the correlation-id cost: **cut the NUMBER of draws first**, and leave the
generator alone until that is done. Its first arm was named as a sweep rather than a benchmark —
how many secure draws does one unary call make, where does each land, is any dead on arrival. The
lead is named in `## Links`, for the reason round 549 records.

Lens RPC-15: re-measure your own record.

**No code changed.** The sweep found the draws already minimal, which is an answer rather than a
fix.

## Hypothesis

From the decision: a call draws for TWO correlation ids, and the responder mints one only to
replace it — so removing that draw takes roughly half the cost without touching the generator.

## Before

```
round 511
token, Random.secure()      30.98 - 37.82 us/token
a whole unary call          88.69 / 101.21 / 101.09 / 97.53 us
```

Which the lead reads as *"about 40 us of every ~97 us unary call is OS entropy for two
correlation ids"*.

## Mechanism

Nothing to change. The consolidation the decision asked for already exists, in three parts that
together leave one mint per call:

- `RpcContextUtils.withTracing` mints ONE token and derives both `req_` and `trace_` from it;
- `traceIdFor` derives the trace id from an existing request id with no mint at all;
- the responder reuses the ids the caller sent rather than minting its own.

**So "the responder mints one only to replace it" is false at this sha** — and it is the code's
own doc comment on `RpcContext.requestId` that says it, which is how the decision came to rest on
it. Rule one, from the inside: the prose was stale and the decision inherited it.

## After

```
  RpcContext.empty() alone      1 token
  the call itself               0 tokens
  one unary call, no context    1 token total

  caller requestId   mint 3
  wire x-request-id  mint 3
  wire x-trace-id    mint 3
  handler requestId  mint 3
  handler traceId    mint 3

  one token                    42.4 us
  one unary call              264.5 us
```

Bench `../probes/P-179-how-many-tokens-one-call-mints.md`. **One token, reused everywhere** —
every id in the call carries the same mint number, which is what rules out "one count, several
ids" as an alternative reading.

The instrument is worth noting: every token's last 4 bytes carry a process-wide monotonic
counter, so a token is its own receipt and both the COUNT and the IDENTITY of each mint are
readable through public API with nothing instrumented.

**`rpc_dart_opentelemetry` was checked, as the decision required** — the lead's `paths:` do not
name it. It reads `record.requestId` for one log attribute and mints nothing, so there is no
hidden draw there and no reader of a responder-minted id. The window the decision worried about
does not exist, because the mint it would have contained does not.

## Gate

```
melos run analyze        SUCCESS  (21 packages + rpc_dart_wasm)
melos run format:check   SUCCESS  (0 changed)
melos run license:check  SUCCESS  (2129 / 2129)
```

**`test:unit` was NOT re-run, and that is stated rather than implied.** Nothing outside
`.claude/loop/` changed — `git status` is five journal files and two new ones — so there is no
behaviour for it to cover. The probe lives under `.dart_tool/`, which no gate step reads. Round
549 set this precedent for a round whose deliverable is a number.

## Canary

**None, and none is possible.** Nothing was switched off: the round counted an existing
mechanism. What stands in for one is the mint-identity column — a wrong count would have shown as
differing mint numbers, and the separate `RpcContext.empty()` measurement is what attributes the
single mint between building a context and making a call.

## What is left, and it is the owner's again

The decision's first step is discharged, by prior work rather than by this round, so its second
step is the whole question: **one token per call costs ~42 us of OS entropy, and the three
options the lead parked are unchanged.**

1. `_fallbackRng` everywhere — ~42 us per call back, ids predictable on every platform rather
   than on node alone.
2. Seed a non-cryptographic generator from ONE secure draw at startup — same saving, sequence
   unguessable without the seed, more code for a property the doc says is not required.
3. Keep it.

What this round adds to that choice is only that the number is now confirmed as ONE token and not
two or three, so option 1 buys ~42 us and not ~84.

## Not fixed

**The cost SHARE is not comparable with round 511's.** That round read ~40 us of a ~97 us call;
this one reads 42.4 of 264.5 over a different rig. Only the token cost travels between them, and
it agrees. Anyone quoting a percentage should re-measure on the rig they care about.

**The context half of the lead is still barely measured.** A 6-link `with*` chain at ~35 us is
synthetic, and `withAdditionalHeaders`' regex re-run plus `forClientRequest`'s two regexes were
never timed. Untouched here.

**The streaming shapes are unmeasured.** One token per UNARY call is what this establishes; a
server-stream or bidi call may mint differently.

**The stale doc comment is left in place**, deliberately: it is the evidence for how the decision
came to rest on a false premise, and rewriting it in the same round that reports it would remove
the thing a reader needs to check. Filed as part of the lead's return to the owner.

## Links

Lead `../backlog/B-120-per-call-context-and-id-cost.md` — back to `awaiting owner`, its first step
discharged and its three options intact.
Bench `../probes/P-179-how-many-tokens-one-call-mints.md` — new.
Round `511-forty-per-cent-of-a-call-is-entropy.md` — the measurement the decision rests on, and
whose title is the percentage this round says does not travel between rigs.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [551]`.
