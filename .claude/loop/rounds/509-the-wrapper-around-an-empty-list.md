---
round: 509
verdict: FIXED
packages: [rpc_dart]
lens: RPC-17
bench: P-147 — new
commit: yes
severity: S3
---

# Round 509 — the wrapper around an empty list

## Target

The two stream middleware helpers in `endpoint/base_endpoint.dart` — twenty-fifth in
the audit's rank, and the direct successor to round 505, which touched the same
field and left this half undone.

Lens RPC-17, in the reading round 507 added to it: *ask what the buffering is FOR,
not only what bounds it.* An `async*` that forwards each message exists to apply
middleware. With no middleware it applies nothing and still costs a hop and an
allocation per message.

## Hypothesis

`_applyRequestMiddlewaresToStream` and `_applyResponseMiddlewaresToStream` wrap every
streaming call even when `_middlewares` is empty.

## Before

Server stream of 10 000 tiny messages, five timed runs per process, run-set minima:

```
always wrapped      5.647 / 5.582 / 5.456   us/message
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b117_broadcast_per_message.dart`

**CONFIRMED.** Round 505 gave the SCALAR helpers an `isEmpty` early return, which
removed the per-message work inside the loop but not the loop itself — the wrapper
still iterated an empty list once per message.

## Mechanism

```dart
Stream<TRequest> _applyRequestMiddlewaresToStream<TRequest>(...) async* {
  await for (final request in requests) {
    yield await _applyRequestMiddlewares<TRequest>(context, request);
  }
}
```

`async*` plus `await for` plus an awaited call per element, to hand each message back
unchanged.

## After

```
bypassed if empty   4.438 / 4.564 / 4.419 / 4.520   us/message
```

Return the source stream unchanged when `_middlewares.isEmpty`; the `async*` body
moves to a private helper used only when there is something to apply. About 1.03 us
per message, roughly 19%.

**This changes a contract, and the round states it rather than letting it be
discovered.** The `async*` form re-read `_middlewares` per message, so a middleware
added mid-stream joined the call in progress. Now the set is fixed when the stream is
built — which is what interceptors already do, their chain being built once and
synchronously at call start. Round 505's record explicitly noted the per-message
re-read as *preserved, not decided*; this is the decision.

Regression: `test/endpoint/a_stream_without_middleware_is_not_wrapped_test.dart`,
4 tests, one of which pins the new contract.

## Canary

`if (false) return ...` on both helpers. The contract test fails —
`Expected: false, Actual: <true>`, a mid-stream middleware rejoining the call — and
the three GUARDs stay green, because the old path was also correct for everything
they assert.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**The other layers the lead names are untouched** and they are where the remaining
~4.4 us per message lives: `handleServerStream`, `_withHandlerSlotStream`,
`StreamBridge`, `_bridgeCallerResponses`, the bidi controller and its `.transform`,
and the `StreamProcessor`/`CallProcessor` controllers that only a no-op listener
reads. The lead also connects these to the dart2js cancel problems the bridges were
added to work around, which nothing here examined.

**The 19% is not user-visible.** At 4.4 us per message this path sustains over
200 000 messages/s on one isolate, which no real transport feeds.

## Method notes this round paid for

**Two run sets are not a measurement when the spread is this wide.** The first
comparison read `4.710` against `5.763` medians and looked settled; the next fixed set
had a median of `5.949`, which would have reversed it. Seven sets later the MINIMA
separate cleanly and never overlap, and minima are the right statistic here because
noise on this machine only ever adds time.

**The bench was reused, not rebuilt.** P-146's file measures exactly this quantity, so
P-147 registers the same file under a new number rather than writing a second one.

## Links

Lens RPC-17. Bench P-147 (new, sharing P-146's file). Lead B-118 (closed). Round 505
is the predecessor that fixed the scalar half and left this one.
