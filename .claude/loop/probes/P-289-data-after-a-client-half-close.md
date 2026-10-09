---
file: packages/core/rpc_dart/.dart_tool/probe/data_after_half_close.dart
round: 798
commit: b204ccd6
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-289 — data after a client half-close

## Measures

A responder over `RpcChannelTransport.fromChannel` with its own
`LogController`; 50 client-stream calls on one connection, each either
`M/Svc/c, DATA(empty)+EOS, DATA(msg)` (arm `late`) or `M/Svc/c, DATA(msg),
DATA(empty)+EOS` (arm `control`). Reports records at warning or above and
the set of message counts the handler saw.

Round 798, before:

```
  arm       records                                        handler counts
  control   0                                              {1}
  late      50 error "Request messages LOST ... accepted   {0}
            2 ... given 1"
```

After: `late` 0 records, handler counts {0}; `control` unchanged.

Found by P-283's log oracle (seed 11, session 9) and its `minlog` minimiser,
which reduced a 60-frame session to the three frames on stream 11.

## Control

`control`: the same three frames in protocol order; the message is
delivered and nothing is recorded.
