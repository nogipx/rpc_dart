---
file: packages/core/rpc_dart/.dart_tool/probe/data_after_client_cancel.dart
round: 799
commit: b7ee3dc2
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-290 — data after a client cancel

## Measures

A responder over `RpcChannelTransport.fromChannel` with its own
`LogController`; 50 client-stream calls on one connection (argv: calls),
each opened with `M/Svc/c, DATA(msg)` and then:

- `control`: `DATA(empty)+EOS`
- `cancel`: an `x-client-cancelled` frame, then `encodeEndOfStream`
- `cancelMsg`: the cancel, then `DATA(msg)`
- `cancelGap`: the cancel, 20 ms, then `encodeEndOfStream`

Reports records at warning or above, grouped by shape, and the set of
message counts the handler returned with.

Round 799, before:

```
  arm         DROPPED   LOST   "send error on inactive processor"
  control     0         0      0
  cancel      50        50     50
  cancelMsg   50        50     50
  cancelGap   0         0      50
```

After: DROPPED and LOST 0 in every arm; the warning column unchanged
(round 800).

Found by P-283's log oracle (seed 11, session 39). `minlog` could not shrink
that session (56 of 60 frames left), because the record depends on a frame
landing inside an await; the stream's own frames, read off the trace, gave the
shape.

## Control

`control`: the same call ended by a half-close instead of a cancel; nothing
is recorded. `cancelGap` is the second control: the same trailing frame
after the cancel's teardown has finished, so it never meets the window,
and it produces no DROPPED or LOST.
