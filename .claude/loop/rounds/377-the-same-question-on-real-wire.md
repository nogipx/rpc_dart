---
round: 377
verdict: CLEAN
packages: [rpc_dart_websocket, rpc_dart_http2, rpc_dart_isolate]
lens: RPC-10
bench: P-67 — new
commit: yes
---

# Round 377 — the same question on real wire

## Target

The gap round 376 named as the largest: **every bidi measurement in rounds
372-376 was taken on an in-process pair.** Round 373 fixed a bidirectional
subscription — a caller that opens the channel, listens, and sends nothing — and
the fix lives in core, but each real transport builds its own metadata frame and
performs its own open. "Core announces the call" is a claim about core; whether
the announcement reaches a peer over a socket is a different question.

RPC-10: what does a transport have to re-implement, and did it? Asked of all
three real ones — websocket, http2, isolate.

## Hypothesis

At least one real transport does not carry the open, so the subscription still
does not reach the server there.

## Before

```
transport                  silent      control
websocket (real socket)    3 DONE      3 DONE
http2     (real socket)    3 DONE      3 DONE
isolate   (real isolate)   3 DONE      3 DONE
```

`silent` is the subscription; `control` is the same handler with a request
stream that CLOSES at once — the case that worked before round 373.

Probes, one per package (P-67):
`rpc_dart_websocket/.dart_tool/probe/bidi_subscription_over_socket.dart`,
`rpc_dart_http2/.dart_tool/probe/bidi_subscription_over_http2.dart`,
`rpc_dart_isolate/.dart_tool/probe/bidi_subscription_over_isolate.dart`.

**Every value is a good one, so the round rests on the ablation.** Round 373's
metadata-frame dispatch removed from core — which all three resolve from local
source through the pub workspace:

```
transport                  silent      control
websocket (real socket)    0 HANG      3 DONE
http2     (real socket)    0 HANG      3 DONE
isolate   (real isolate)   0 HANG      3 DONE
```

Every `silent` collapses, every `control` survives. **So the defect was real on
all three real transports**, not only on the in-process pair 373 measured, and
373's fix is what carries them. Tree restored, `git diff --stat` empty, all
three re-measured back to `3 DONE`.

## Mechanism

n/a — nothing is broken. What the ablation establishes is that the fix is
transport-independent for the right reason: the open is announced by the CALLER
(`_queueInitialMetadataIfUnsent` in the constructor) and dispatched by the
shared PIPELINE, so a transport only has to carry a metadata frame it already
carries. http2 was the one worth checking hardest — the shape maps onto HEADERS
then DATA, and a caller with no message must still get its HEADERS out.

## After

n/a — no change made. Pinned by one test per package, each a witness plus the
control:

- `rpc_dart_websocket/test/bidi_subscription_over_socket_test.dart`
- `rpc_dart_http2/test/bidi_subscription_over_http2_test.dart`
- `rpc_dart_isolate/test/bidi_subscription_over_isolate_test.dart`

## Canary

n/a — no fix. The ablation is the variation and the whole evidence, and it is
the strongest form this class admits: it shows the defect was present on three
transports whose own round never ran, and that one core fix covers all of them.

## Gate

All four green: `melos run analyze`, `melos run test:unit --no-select`,
`melos run format:check`, `melos run license:check`. Six new tests across the
three transport packages, all passing.

## Not fixed

Nothing found. What remains unmeasured of bidi, narrower now than it was:

- **Latency.** All three probes run on loopback. A link with a real round trip
  is still untested, and P-58's lesson is that it can change a flow-control
  answer entirely. Note this round's question is not flow-control shaped, so
  loopback is adequate FOR IT — the caveat is about the other bidi results.
- **The request direction of `_pipelineFedRequestStream`** (named in 374).
- **`abort()`**, a deadline mid-duplex, and **dart2js/web**, where
  `melos run test:web` is red on an unrelated arm (B-48).

## Links

- RPC-10 — the lens; `applied:` gains 377
- P-67 — the bench, three packages
- C-43 — the negative
- Round 373 — the fix; round 376 — the first re-measurement, which named this gap
- L-05 — a gate ablation proves sensitivity, not portability; this round is the
  portability half, done by running the real transports rather than arguing
