---
status: closed (round 627)
round: 627
commit: 463fdf60
paths: [packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: none — audit probes `packages/core/rpc_dart/.dart_tool/probe/audit_consumers_server_stream_silence.dart`, `audit_lifecycle_raw_frames.dart`, not yet registered
reason: "FIXED in round 627: the responder answers INVALID_ARGUMENT when its request stream ends with no request; four empty-frame calls read [3, 3, 3, 3] and the slot comes back. Previously: bench — a server-stream whose bound request stream ends with zero messages gets no status, and keeps its state and handler slot until the connection closes"
---

# B-230 — a server-stream with no request is never answered

Found twice by the independent audit of 2026-10-02 (lifecycle and cross),
reproduced before filing.

## The shape

Any payload frame binds the responder in `_ensureResponder`, including one that
decodes to no message: an empty DATA frame, or a bare 5-byte prefix (B-231).
Binding takes a handler slot and cancels the half-open timer. The half-close then
goes `_handleEndOfStream` -> `endRequests()` and returns before the pipeline's
"closed without payload" INVALID_ARGUMENT, which only fires while no responder is
bound. `ServerStreamResponder`'s request `onDone` only logs, so with no request
handled nothing sends a trailer and `done` never completes.

## Measured

```
maxConcurrentHandlers 4, four such calls     statuses after 3 s [[], [], [], []]
next unary on the connection                 status 8 Too many concurrent handlers
default policy, 3000 such calls              answered 0, activeResponders 3000
control, no DATA frame                       [[3], [3], [3], [3]], next unary served
```

The other three shapes answer the same frames (unary 13, client 0, bidi 0).

## Fix direction

`ServerStreamResponder`'s request `onDone` with no request handled answers
INVALID_ARGUMENT, as the unbound path does.

## Owner decision

—
