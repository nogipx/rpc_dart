---
status: open
round: 547
commit: c8ce033a
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: P-155
reason: "found while fixing B-126's unary half: a peer that half-closes MID-FRAME gets INVALID_ARGUMENT on unary and is left to its deadline on a server stream. Measured, and independent of that round's change — the arm reads status 4 with the fix in place and with it ablated"
---

# B-216 — a server stream hangs when the peer stops mid-frame

Found by round 547's second witness arm, which exists because B-126's decision required it:
tolerating an incomplete frame must not mean waiting for one forever.

```
peer stops mid-frame
   unary         status 3: Request stream closed mid-message for Svc.echo:
                           the last gRPC frame is incomplete
   server stream status 4: Deadline exceeded
   client stream got:0
```

Bench `../probes/P-155-does-unary-survive-a-fragmented-frame.md`, `truncate` arm.

**Independent of round 547.** That round's new guard is gated on `is UnaryResponder`, and the
server-stream column reads `status 4` both with the fix in place and with the guard ablated
(canary D). The shape was always this way; nothing looked until the arm existed.

## Why it matters

A peer that sends half a message and half-closes costs the server a live call until its deadline
— and if the caller set none, for the life of the connection. The unary path now answers
immediately; the server-stream path does not, on the same input, through the same pipeline.

RPC-08's shape once more: one pipeline, three shapes, and the ending each gives a peer differs
with nothing saying so.

## Why the unary fix does not reach it

A server-stream responder is bound to a message stream (`_stateBoundStream`) and its processor
waits for a complete frame, so the pipeline has nowhere to notice. `_handleEndOfStream`'s
unary/server-stream branch only answers when `state.responder == null`, and by then it is bound.

## The third column is worth its own look

`client stream got:0` — the truncated frame is treated as ZERO messages and the call SUCCEEDS.
Better than a hang and arguably worse than a status: the handler is told the peer sent nothing,
where in fact it sent an incomplete something. Whether that should be INVALID_ARGUMENT is the
same question this lead asks for server-stream.

## Witness a round would build

P-155's `truncate` arm already is one. What it needs is the fix: an incomplete frame at
half-close answered rather than awaited, for the two shapes that do not do so.

The hard part is where. The processor owns the parse and the pipeline owns the half-close, so the
signal has to cross that boundary — which is the same seam round 547 crossed for unary with
`requestHandled`, and the reason it needed a public getter.

## Owner decision

—
