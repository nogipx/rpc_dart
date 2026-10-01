---
status: open (round 565)
round: 551
commit: 12669b0f
release: none
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/core/metadata.dart]
probe: P-149
reason: "cost — the GENERATOR half is decided (keep `Random.secure()`, round-565 review) and what remains is the context-copy half: `Map.from` twice per `with*`, `withAdditionalHeaders` re-running the header regex over all headers, `forClientRequest`'s two regexes. None of that has been measured against the chain a real call builds"
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

## The three options, and the round-540 decision that came before this one

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

## The sweep (round 551) — the draws were ALREADY cut

`../rounds/551-the-draws-were-already-cut.md`. Bench `P-179`.

```
  RpcContext.empty() alone      1 token
  the call itself               0 tokens
  one unary call, no context    1 token total

  caller requestId / wire x-request-id / wire x-trace-id /
  handler requestId / handler traceId      ALL mint 3

  one token  42.4 us        one unary call  264.5 us
```

**ONE token per call, reused everywhere — the decision's premise does not hold.** The
consolidation it asked for already exists: `withTracing` mints once and derives both `req_` and
`trace_`; `traceIdFor` derives from an existing request id with no mint; the responder reuses
what the caller sent and mints nothing.

**"The responder mints one only to replace it" is this lead's own doc comment on
`RpcContext.requestId`, and it is false at this sha.** That is how the decision came to rest on
it — rule one from the inside. The comment is deliberately left in place so a reader can check
the claim against the code themselves.

**`rpc_dart_opentelemetry` checked**, as the decision required since these `paths:` do not name
it: it reads `record.requestId` for one log attribute and mints nothing. The pre-replacement
window the decision worried about does not exist, because the mint it would have contained does
not.

**The instrument needed no instrumentation**: every token's last 4 bytes carry a process-wide
monotonic counter, so a token is its own receipt and both the count and the identity of each mint
are readable through public API.

### So the three options below are the whole question now

One token costs ~42 us, confirmed. Option 1 therefore buys **~42 us, not ~84** — which is the
only thing this round changes about the choice. Nothing else about it moved.

The cost SHARE is NOT comparable with round 511's `~40 of ~97 us`: this rig reads 42.4 of 264.5
over a byte pipe with 2000 sequential calls. Only the token cost travels, and it agrees (42.4
against 30.98-37.82).

## Still open, barely measured

**The context half.** A 6-link `with*` chain costs ~35 us, but that is a synthetic
worst case rather than what a call builds, so it is not a share of a call and the
probe says so in its own output. `withAdditionalHeaders` re-running the header regex
over all headers, and `forClientRequest`'s two regexes, were not measured at all.

Whoever takes that half should measure the chain a REAL call builds, not a
constructed one — the mistake an earlier draft of P-149 made was quoting the
synthetic number as "37.8% of a call".

## Owner decision

**DECIDED in the round-565 review: the two ids ARE needed, so the generator stays
`Random.secure()` — option 3, and the ~42 us stays with it.**

The answer came as a question first — *why are two ids needed at all? if they really are needed,
keep it as is* — so the condition is what had to be established. It holds, read at HEAD
(`182ec83e`), in three parts.

**Cutting one id would save nothing on the path that was measured.** The two ids already share
ONE mint: `withTracing` (`context.dart:534`) mints a token and derives both `req_` and `trace_`
from it, `traceIdFor` (`:547`) derives the trace id from an existing request id with no mint, and
`_ensureCallerContext` (`caller_pipeline.dart:137-148`) is the only outbound path and uses the
deriving forms. So the ~42 us is one token whether a call carries one id or two, and the owner's
question does not reach the cost.

**They are not interchangeable, and one of them has consumers outside this library.** A request
id names one call — `retry_interceptor.dart:26` and `:62` point servers at it as a dedup key for
retries. A trace id names a chain that may span several calls and several services: it is read
back off the wire at `responder_pipeline.dart:2356`, and `rpc_dart_opentelemetry` emits it as its
own attribute (`rpc.trace_id` at `otel_rpc_interceptor.dart:65`, `log.trace_id` at
`log_controller_otel_output.dart:174` and `:244`). Drop it and a trace supplied by the
application (`withTracing(traceId:)`) or forwarded by a peer can no longer be joined across
calls. By default rpc_dart derives the trace from the request, so a default trace covers exactly
one call — that is the case where the second id carries nothing new, and it is not the only case.

**Where two ids DO cost two mints: a peer that sends no `x-trace-id`.** `responder_pipeline.dart`
adopts the caller's request id at `:2341-2345` and then, at `:2359-2361`, calls
`generateTraceId()` — a fresh token — where the caller side calls `traceIdFor`. Any non-rpc_dart
gRPC client sends neither header, so such a call costs the RESPONDER two tokens where an
rpc_dart peer costs it none. Filed as `B-220`; it is a one-line consolidation of the kind round
551 reported as already complete, and it is not a posture question, so this decision does not
touch it.

`release: none`. Nothing changes for any caller, so nothing is owed; the earlier
`release: changelog` belonged to option 1, which was not taken. The three options above stay on
the record as the reasoning, not as a live question.

**THIS LEAD STAYS OPEN**, and not for the generator. What is left is the context-copy half in
`## Still open, barely measured` — ordinary measurable work with nothing of the owner's in it.
`round:` and `commit:` are moved to round 551's sha, since that is the measurement the lead now
rests on and the ageing check had been comparing against round 511's.
