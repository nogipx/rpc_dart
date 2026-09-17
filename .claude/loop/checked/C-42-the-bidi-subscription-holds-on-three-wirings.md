---
round: 376
commit: 34aeff10
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/peer_endpoint.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**]
scope: [rpc_dart]
---

# C-42 — the bidi subscription fix holds on three wirings

Round 373 fixed a bidirectional subscription — a caller that sends nothing and
never half-closes — and proved it on one wiring. Asked of three more:

```
wiring              silent      control
peer endpoint       3 DONE      3 DONE
zero-copy           3 DONE      3 DONE
8 concurrent        8 of 8      n/a
```

Pinned by `test/streams/bidi_subscription_on_every_wiring_test.dart`.

## Control

**Every value above is a good one, so this record rests on the ablation.**
Removing 373's metadata-frame dispatch:

```
wiring              silent      control
peer endpoint       0 HANG      3 DONE
zero-copy           0 HANG      3 DONE
8 concurrent        0 of 8      n/a
```

Every `silent` collapses and every `control` survives, which says two things:
the probe sees the defect on all three wirings, and the defect was genuinely
present on all three — so the fix is load-bearing here, not merely untested.

A per-arm control rides along: `control` is the same handler driven with a
request stream that closes at once, the case that worked before 373.

## What it does NOT cover

- **Real transports.** http2, websocket and isolate each build their own
  metadata frame; none is exercised. This is the largest remaining gap in the
  bidi work.
- Latency (the in-process pair flattens it), the request direction of
  `_pipelineFedRequestStream`, `abort()`, a deadline mid-duplex, and dart2js.

Re-run when the responder pipeline's dispatch or the peer endpoint's message
filter changes.
