---
file: packages/core/rpc_dart/.dart_tool/probe/bidi_request_sink_errors.dart
round: 384
commit: 69d24a76
paths: [packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-72 — what the server keeps when a bidi request sink errors

## Why it exists

`BidirectionalStreamCaller.abort()`'s own doc says a request stream that ERRORS
has no signal to the peer and parks its handler for good. The endpoint bridge
answers that with `cleanup(abortPeer: true)`; `requestSink`'s `onError` logged
and returned. This measures what the server is left holding.

## Measures

Four counters after each scale and again three seconds later: the responder
pipeline's `openStreams` and `activeResponders`, the handler's own live count
(incremented on entry, decremented in a `finally`), and the server transport's
`flowControlStateSizes['sendCredit']`. Plus `got` — requests the handler
actually received — which is what tells a leak apart from a lost message.

Scales 1, 5, 20 on ONE connection (L-08). A count that tracks the call count is
retention; one that returns to zero is churn.

## The arms, and why each is there

- `sinkAddError` — `requestSink.addError(...)`
- `sinkAddStreamErr` — `addStream(s)` where `s` throws right after its last
  message
- `sinkAddStreamErrPaced` — the same with a 40 ms beat before the throw. This is
  the one that separates *the fix drops a message* from *the abort raced a
  message still in flight*, and it earned its place: without it the drop from
  `got=2` to `got=1` reads as a regression
- `control-close` — `requestSink.close()`, the healthy half-close
- `control-abort` — the same error followed by an explicit `abort()`

## Control

Two controls, and they differ from the case by exactly one thing — whether the
peer is told. Both read 0 at every scale while the two erroring arms read
1 / 6 / 26, unchanged after +3 s.

The ablation is the other direction: `if (1 > 0) return;` in the sink's
`onError` takes the fixed tree back to 20 held on core and 5 on each of the
three real transports, with every GUARD staying green.

## The numbers (round 384)

```
arm                         1 call   5 calls   20 calls   +3s
sinkAddError                  1->0      6->0      26->0    26->0
sinkAddStreamErr              1->0      6->0      26->0    26->0
sinkAddStreamErrPaced         0         0          0        0     (got 2/12/52)
control-close                 0         0          0        0
control-abort                 0         0          0        0
```

## What it establishes, and what it does not

Establishes: an erroring bidi request sink used to pin the server's stream
state, responder, live handler and flow-control credit permanently, and does
not now.

Does not establish anything about the CONNECTION's health afterwards — that
needs a call on the same connection after the ending, which the transport
witnesses do and which is how B-53 was found. Nor about latency: this runs on a
pair. Nor about a `send()` that throws (C-35: unreachable).
