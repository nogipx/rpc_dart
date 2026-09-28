---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-111 — RpcRateLimiter: the first matching counter wins, so `global` is bypassed; streaming calls are not admitted through it

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_resolveCounter` returns method → service → fallback → global, so a method with its own limit ignores the global cap entirely; client-stream and bidi only meter MESSAGES, so a call with zero request messages (a bidi subscription) is never limited; per message, the key extractor and method-key string are rebuilt.

## The shape

`packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart` `_resolveCounter` returns the first non-null
counter; `interceptClientStream`/`interceptBidirectionalStream` wrap only the
request stream in `_meterStream`, which calls `_resolveCounter` (string build,
`_keyExtractor`, LRU re-insert) for every message. `_statusResourceExhausted = 8`
duplicates `RpcStatus.resourceExhausted`.

## Why it matters

An operator setting `global: 100/s` plus a looser per-method limit gets no global
bound on that method; subscriptions are unlimited.

## Witness a round would build

`global: 10/s`, `perMethod: {A: 1000/s}`; 100 calls to A in one second. Expected
today: all admitted. Second arm: 100 bidi subscriptions with no request messages.

## Fix sketch

Check every applicable counter (all must admit, charge only if all do); check
admission at call start for every shape; cache the resolved counter per call.
If "most specific wins" is intended, document it and rename `global`.

## Owner decision

—
