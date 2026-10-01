---
file: packages/core/rpc_dart/.dart_tool/probe/b120_draws_per_call.dart
round: 551
commit: 12669b0f
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
status: valid
---

# P-179 — how many tokens does one unary call mint, and where does each land?

## Why it exists

B-120's decision was to cut the NUMBER of secure draws before touching the generator, on the
reading that a call mints two correlation ids and *"the responder mints one only to replace
it"*. That is the code's own claim in `RpcContext.requestId`'s doc, and it had never been
measured. A round acting on it would have been optimising a count nobody had counted.

## The harness

**No instrumentation, because none is needed.** Every token's last 4 bytes carry a process-wide
monotonic counter (`_uniqueToken` puts it there so two tokens cannot collide), so a token IS a
receipt: base64url-decode it and bytes 12..16 are its mint number.

That makes two things readable through public API alone:

- **how many** — mint one token before and after an operation and subtract, minus the one the
  reading itself cost;
- **which one** — decode the id the caller holds, the ids on the wire, and the ids the handler
  receives, and compare mint numbers. Same number means one token reused; different numbers mean
  separate mints.

A warm-up call runs first and is discarded: the first call pays for lazy statics, and the
decision is about the steady state.

The cost arm times `RpcContextUtils.generateTraceId()` — exactly one token — rather than
ablating `_strongRng`, so it needs no edit to `lib/`. That is only legitimate because the mint
counts establish the token is the whole of a call's entropy.

## The numbers (round 551)

```
  RpcContext.empty() alone      1 token
  the call itself               0 tokens
  one unary call, no context    1 token total

  caller context  requestId=req_...AAAAAw   (mint 3)
  on the wire     x-request-id=req_...AAAAAw (mint 3)
  on the wire     x-trace-id=trace_...AAAAAw (mint 3)
  responder side  handler requestId=req_...AAAAAw   (mint 3)
  responder side  handler traceId=trace_...AAAAAw   (mint 3)

  one token                    42.4 us
  one unary call              264.5 us
```

**One token per call, and every id in the call is that same token.** `withTracing` mints once
and derives both `req_` and `trace_` from it; `traceIdFor` derives the trace id from the request
id with no mint at all; the responder reuses what the caller sent.

## Its mint decoder is wrong about half the time (found in round 566)

`_mintOf` takes the token body with `token.split('_').last`, and **base64url's
alphabet contains `_`** — so for any token whose body holds one, it decodes a
fragment, gets the wrong length and returns null. The recorded run above was not
affected (every row shows a mint number, and `_counterNow()`'s `!` would have
thrown rather than lied), so the numbers stand; what the defect costs is
reliability, not correctness. P-188 uses `indexOf('_')` instead.

## Measures

Mints, by counter delta, and mint IDENTITY, by decoding each id. Then one token's cost and one
call's, in microseconds over 2000 iterations.

## Control

**`RpcContext.empty()` alone, measured separately at 1 token.** It is what makes `the call
itself: 0` meaningful — without it a total of 1 could not be attributed between building the
context and making the call.

**The mint NUMBERS are the second control, and the stronger one.** A count of 1 is consistent
with one mint reused and with one mint plus several ids that are not tokens at all. Identical
mint numbers across the caller, the wire and the handler rule that out.

## What it establishes, and what it does not

Establishes that a unary call mints ONE token, that the responder does not mint one of its own,
and therefore that the premise B-120's decision rests on does not hold at this sha.

**Both of those hold for the one PEER this ran against: an rpc_dart caller through
`RpcCallerEndpoint`, which always sends `x-request-id` AND `x-trace-id`.** The responder adopts
both and mints nothing. Where no `x-trace-id` arrives — any gRPC client that is not rpc_dart,
since both headers are this library's own — `responder_pipeline.dart:2360` mints a second token,
and no arm here reaches that branch. Read in the round-565 owner review and filed as `B-220`; the
rig needs no change to cover it, only a request carrying neither header.

Does NOT compare its cost SHARE with round 511's. That round read ~40 us of a ~97 us call; the
call here is 264.5 us over a different rig (a byte pipe, 2000 sequential calls), so only the
TOKEN cost — ~42 us against its 31-38 us — is comparable. The share is not.

Does NOT cover the streaming shapes. A server-stream or bidi call may mint differently and
nothing here varies the shape.

Does NOT measure the context-copy half of B-120, which is a separate claim in the same lead and
still barely measured.
