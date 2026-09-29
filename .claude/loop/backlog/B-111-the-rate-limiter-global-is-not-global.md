---
status: awaiting owner
round: 502
commit: 33551cce
paths: [packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart]
probe: P-140
reason: "the streaming half is CONFIRMED and fixed in round 502 — a call sending zero request messages was never charged, 100 of 100 admitted against a limit of 5. The per-method/global half is measured and matches the contract the class doc states in words, so it needs the owner's decision rather than a round's"
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

## Outcome (round 502) — the streaming half is fixed

**CONFIRMED and fixed.** 100 calls against `global: max 5`:

```
                                 before   after
CONTROL unary                         5       5
CONTROL bidi, 1 request message       5       5
bidi, ZERO request messages         100       5
client-stream, ZERO messages        100       5
```

`interceptClientStream` and `interceptBidirectionalStream` only wrapped the request
stream, and `_meterStream` charges in `handleData`, so a call whose request stream
is empty was never charged at all. A bidi subscription is exactly that shape.

Fixed with `_check(call)` before `next` on both shapes plus
`_meterStream(..., firstIsPrepaid: true)`, so a streaming call costs
`max(1, messages)`. The prepaid half matters: charging establishment ON TOP closed
the hole equally well but halved the effective limit for every one-message call,
which the `CONTROL bidi, 1 request message` arm reads as 2 instead of 5.

## Owner decision

**The per-method/global half. Measured and unchanged: `global: 5` with `perMethod: {'Feed.hot': 1000}` admits
100 of 100 calls to `Feed.hot`.** The global cap does not apply.

**But the class doc states this as the contract, in words:** *`perMethod[key]` >
`perService[key]` > `perKeyFallback[key:method]` > [global] — the first that
matches, and only that one.* So this is a decision someone made and documented,
which puts it outside what a round may reverse. Recorded here with the number
attached.

The hazard is narrower than the lead implies: it requires a per-method limit
LOOSER than the global one, which is a self-contradictory configuration, and the
doc's own example has per-method tighter (`global: 5000`, `perMethod: 10`). What is
missing is not enforcement but any signal that the config contradicts itself.

Three options:

1. **Accept it.** The contract is documented and the common configuration is
   unaffected. Cost: an operator who reads `global` as "a cap on everything" — the
   ordinary reading of the word — is wrong, and nothing tells them.
2. **Warn at construction.** Normalise each spec to a rate (`max / window`) and
   throw or log when a `perMethod`/`perService` entry exceeds `global`'s. Cheap,
   non-breaking, catches the only case that hurts. Needs a decision on throw vs
   warn, and on how to compare a token bucket's burst against a sliding window.
3. **Make every applicable counter apply** — all must admit, charge only if all
   do. Matches the word `global` and is what the lead asks for. It is a breaking
   behaviour change for anyone relying on the documented precedence, and it makes
   a call cost a token in several counters at once.

A fourth, orthogonal to all three: rename `global` to something that does not
promise universality (`defaultLimit`, `fallback`). Breaking at the API level,
honest at the conceptual one.

## Still open, not measured here

- `_statusResourceExhausted = 8` duplicates `RpcStatus.resourceExhausted`.
- `_resolveCounter` rebuilds the method-key string and re-runs `_keyExtractor` on
  every message. The re-resolution is deliberate and commented (it rebinds to the
  canonical counter after an eviction), so any change needs the eviction case
  measured first. Cost, not correctness.
