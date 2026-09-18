---
round: 385
commit: 8315658d
paths: [packages/transport/rpc_dart_isolate/lib/**, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/bidirectional/**]
scope: [rpc_dart_isolate, rpc_dart]
---

# C-45 — bidi over a real isolate, serialized and zero-copy

C-44 took C-41's endings and P-64's duplex cases to a real websocket. This is
the same matrix over a real spawned isolate — the owner's second transport, and
the only one whose channel is not a socket: SendPort/ReceivePort, frames that
are `_IsolateMessage`s.

It also covers the one thing no endings matrix had ever run: **zero-copy**, the
codec-less path through `_ensureBidirectionalResponder`.

```
arm                serialized            zero-copy (no codecs)
unary (control)    baseline, usable      n/a
normal             baseline, usable      baseline, usable
consumerCancel     baseline, usable      baseline, usable
tokenCancel        baseline, usable      baseline, usable
handlerThrows      baseline, usable      baseline, usable
deadline           +5 / +12 / +12        +5 / +12 / +12
neverFinish        baseline, usable      baseline, usable
fullDuplex         30/30 ORDER PRESERVED 30/30 ORDER PRESERVED
concurrent         8 of 8 clean          8 of 8 clean
```

**The two modes agree in every cell.** The `deadline` row is the same bounded
`_reclaimGrace` retention websocket shows and is not a defect (L-15, C-44).

The counters are reported OVER THE WIRE by a unary `stats` method, because the
responder lives in another isolate and cannot be read from the test side. That
call owns a stream while it runs, which is why the baseline is 1 rather than 0
and why the unary arm exists — it fixes the baseline in the same run.

## Control

Three, since most cells are at a baseline rather than at zero. The unary arm
fixes the baseline. The `deadline` row is the sensitivity proof: the only arm
that reads above it, so the instrument demonstrably reports retention. And the
serialized pass is the control for the zero-copy pass — same endings, same
scales, same worker, differing only in whether codecs were given.

## What this does NOT cover

Latency, which has no analogue on an isolate port and was deliberately not
simulated. A worker that dies mid-call. Payloads large enough to engage flow
control. RSS, and anything no counter names.

Re-run when a bidi ending changes, or when the isolate transport changes how it
opens or tears down a stream.
