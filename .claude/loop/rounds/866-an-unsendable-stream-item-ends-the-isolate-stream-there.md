---
round: 866
verdict: CLEAN
packages: [rpc_dart_isolate]
lens: RPC-25
bench: none — the witness is the existing isolate test, its expectation tightened; nothing quantitative beyond the item list
commit: yes
release: none
---

# Round 866 — an unsendable stream item ends the isolate stream there

## Target

KV-MP-02 (unsendable payloads) on the isolate transport, after round 862.
Round 862 measured a codec failure on the channel family and http2; the
isolate's zero-copy path fails differently (`SendPort.send` throws on an
unsendable object). Its existing test asserted the error and that item 2
was missing, but not that nothing followed, which is the gap 862 closed.

## Hypothesis

On the isolate's zero-copy path, a stream item that cannot be sent ends
the stream there. Fails if later items arrive.

## Before

```
unsendable_direct_object_test, "a stream item that cannot be sent ...",
expectation tightened to items == [0, 1]:
  current tree                          items [0, 1], INTERNAL
  round 862's server check switched off items [0, 1, 3, 4], INTERNAL
```

## Mechanism

None at the transport: the direct-object send failure is recorded by the
same `_transmitResponse` catch as a codec failure, and round 862's pump
stop answers it.

## After

n/a — the test's expectation is now `[0, 1]`, so the gap cannot return
unseen.

## Canary

The control above: round 862's check off, `Expected: [0, 1] Actual: [0,
1, 3, 4]`; restored, green.

## Gate

`melos run analyze` SUCCESS; `melos run test:unit --no-select` SUCCESS
(isolate +102, rpc_dart +2231 ~1, http2 +358, http +261, websocket +331,
conformance +512 ~150); `format:check` SUCCESS; `license:check` compliant.

## Siblings

—

## Not fixed

Bidi over the isolate and the web worker variant were not measured.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Negative
`../checked/C-94-an-unsendable-stream-item-ends-the-isolate-stream-there.md`.
Round `862-a-response-that-cannot-be-sent-ends-the-stream.md`.
