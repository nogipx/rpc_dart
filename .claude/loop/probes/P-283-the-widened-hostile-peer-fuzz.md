---
file: packages/core/rpc_dart/.dart_tool/probe/fuzz_control_frames.dart
round: 789
commit: 272098cf
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/rpc/streams/**]
status: valid
---

# P-283 — the widened hostile-peer fuzz

## Measures

The gate's `test/fuzz/hostile_peer_and_chaos_test.dart`, widened: per
session, 60 frames on seven ids over `RpcChannelTransport.fromChannel`
(`halfOpenStreamTimeout: 200ms`), drawn from metadata, data and end-of-stream
(mode `noControl`, the gate's own kinds) plus, in mode `full`, cancels,
per-stream and connection grants with hostile values (`-1`, `2^63-1`,
`99999999999999999999`, `abc`, empty, ...), and a frame that is a request, a
cancel and a grant at once. Then an epilogue an honest peer would send:
half-close and credit every id. Oracles: nothing reaches the zone; a later
valid call is answered; after 600 ms the OPEN connection holds no
responder; after close, none. argv: `sessions seed mode`, or
`min seed session mode` to minimise a failing session.

Round 787, before its fix: `noControl`, seed 7, failed 2 of 60 sessions
(the empty-unary leak). Round 789, after it, 120 sessions per run:

```
  seed   noControl   full
  7      0           0
  11     0           0
  23     0           0
  42     0           0
  99     0           0
```

## Control

The round-787 run of the same seed before the fix, where the oracle fired
(2 failures); its minimiser reduced one session to the four frames P-281
measures. So the bench can see a held responder on an open connection.
