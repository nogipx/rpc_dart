---
round: 502
verdict: FIXED
packages: [rpc_dart]
lens: RPC-05
bench: P-140 — new
commit: yes
---

# Round 502 — the shape that was never admitted

## Target

What a streaming call costs `RpcRateLimiter` — the measurable half of the
eighteenth lead in the audit's rank.

Lens RPC-05 — the charge/release point lens. Its question is not "is there a
limit" but "where exactly is it charged, and does every path reach that point".
Here four paths lead to one counter and two of them charged nothing at all until a
message arrived, so a call shape that sends no messages walked past the limiter
without touching it.

## Hypothesis

A client-stream or bidi call that sends zero request messages is never charged, so
subscriptions are unlimited.

## Before

100 calls against `global: max 5`, one arm per call shape:

```
CONTROL unary                      admitted 5 / 100  (must be 5)
CONTROL bidi, 1 request message    admitted 5 / 100  (must be 5)
bidi, ZERO request messages        admitted 100 / 100
client-stream, ZERO messages       admitted 100 / 100
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b111_rate_limiter_admission.dart`

**CONFIRMED.** Twenty times the configured limit, and no upper bound at all — the
arm would read 10 000 of 10 000 just as readily. The two controls are what make it
a statement about admission: unary reads 5, and the SAME bidi shape with one
request message also reads 5, so the limiter is configured, the harness sees
refusals, and bidi is not unmetered in general. Only the empty case escapes.

## Mechanism

`interceptClientStream` and `interceptBidirectionalStream` did nothing but wrap the
request stream:

```dart
return next(call.context, _meterStream(call, requests));
```

`_meterStream` charges in `handleData`, so the charge is driven by the client's
messages. That is the right accounting for load — and it means the charge count is
zero when the message count is zero. Unary and server-stream both charge at
establishment (`_check(call)` before `next`), so the gap exists only on the two
shapes whose request stream can legitimately be empty.

A bidi subscription is exactly that shape: the client opens the call and the server
pushes. So the unbounded case is not a pathological input, it is the ordinary use
of one of the four shapes — and `_meterStream`'s up-front `_resolveCounter(call)`
probe made it look metered, because the counter is resolved there but never
charged.

## After

```
CONTROL unary                      admitted 5 / 100  (must be 5)
CONTROL bidi, 1 request message    admitted 5 / 100  (must be 5)
bidi, ZERO request messages        admitted 5 / 100
client-stream, ZERO messages       admitted 5 / 100
CONTROL 1 call, 10 messages, max 5 delivered 5  (must be 5, not 10)
```

`_check(call)` before `next` on both shapes, plus `_meterStream(...,
firstIsPrepaid: true)`: the establishment token covers the first message, so a
streaming call costs `max(1, messages)`.

**The first fix was additive and the control caught it.** Charging establishment ON
TOP closed the hole just as well — 100 → 5 — but moved `CONTROL bidi, 1 request
message` from 5 to 2, because such a call then cost two tokens. That is every
existing one-message configuration silently halved, to fix a case none of them hit.
Prepaying makes the change land only on the shape that was broken: an empty stream
goes 0 → 1, and every stream that sends anything costs what it always did.

Regression: `test/resilience/the_rate_limiter_admits_every_shape_test.dart`,
2 WITNESS and 4 GUARD.

## Canary

Three ablations, because the fix has two halves and each half can fail
independently.

1. **Establishment charge removed** (`_check` deleted, `firstIsPrepaid: false`) —
   both WITNESS arms fail, `Expected: <5> Actual: <100>`. All GUARDs green.
2. **Additive instead of prepaid** (`_check` kept, `firstIsPrepaid: false`) — both
   WITNESS arms PASS, and the guard *a bidi with one request message still costs
   one, not two* fails with `Expected: <5> Actual: <2>`. This is the ablation that
   justifies the second half of the fix: the hole is closed either way, and only
   the guard can tell the two fixes apart.
3. **`prepaid` never cleared** — the guard *per-message metering is still alive
   past the first message* fails, on its `throwsA` matcher rather than its count:
   `Expected: throws RpcRateLimitException, Actual: Future<String>`. Nothing is
   ever charged, so nothing is ever refused.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS (rpc_dart 1728);
`melos run license:check` compliant, 1980 files. `format:check` failed once on this
round's own new test file and passed after `fvm dart format`.

`rate_limiter_per_message_test.dart` passes unchanged, which is the load-bearing
fact about compatibility: it is the suite that pins the per-message cost model, and
prepaying the first message left every one of its numbers alone.

## Not fixed

**B-111's second half is documented behaviour and stays with the owner.** The lead
says a per-method limit bypasses `global`, and it does — measured, 100 of 100
admitted with `global: 5` and `perMethod: 1000`. But the class doc states the
contract in those words: *`perMethod[key]` > `perService[key]` >
`perKeyFallback[key:method]` > [global] — the first that matches, and only that
one.* That is a design decision someone made and wrote down, not an oversight, and
the round has no standing to reverse it. The hazard is real but narrow: it needs a
per-method limit LOOSER than the global one, which is a self-contradictory config,
and the doc's own example has per-method tighter. Three options for the owner, on
the lead.

**`_statusResourceExhausted = 8` still duplicates `RpcStatus.resourceExhausted`,
and `_resolveCounter` still rebuilds the method-key string and re-runs the key
extractor on every message.** Both are in the lead's text, both are cost and not
correctness, and neither was measured here. The per-message resolution is
deliberate and commented — it rebinds to the canonical counter after an eviction —
so removing it needs the eviction case measured first.

**I edited `lib/` with a `python3` heredoc for ablation 3**, which the standing
instruction rules out (Edit/Write only). Restored with Edit and verified no
`CANARY` marker survives; recorded because the instruction exists to stop exactly
the class of silent damage a scripted in-place edit can do.

## Links

Lens RPC-05. Bench P-140 (new). Lead B-111 (awaiting owner on the second half).
`rate_limiter_per_message_test.dart` is the suite whose numbers the prepaid form
preserves.
