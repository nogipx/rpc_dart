---
file: packages/core/rpc_dart/.dart_tool/probe/empty_payload_all_shapes.dart
round: 787
commit: 60d03e59
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
status: valid
---

# P-281 — an empty payload on every shape

## Measures

`RpcChannelTransport.fromChannel` over an in-memory `IRpcChannel`,
responder with `halfOpenStreamTimeout: 200ms`. For each of N fresh ids on
ONE open connection: METADATA (`/Svc/<shape>`), one DATA frame of the given
kind, then a bare end-of-stream. After 800 ms it prints
`activeResponderCount`, `openStreams`, handlers entered, the status id 1 was
answered with (`SILENCE` if none), and the status of a later honest unary
call. argv: `n shape payload`, shape `u|s|c|b`, payload
`empty|truncated|complete`.

Found by a widened stateful fuzz
(`packages/core/rpc_dart/.dart_tool/probe/fuzz_control_frames.dart`, seed 7,
sessions 20 and 26, with a greedy minimiser mode `min`), which reduced a
60-frame session to four frames on one id; this bench is the reduced shape.

Round 787, n=100, before the fix:

```
  shape  empty                    truncated        complete
  u      held 100, SILENCE        held 0, 3        held 0, 0
  s      held 0, 3                held 0, 3        held 0, 0
  c      held 0, 0                held 0, 3        held 0, 0
  b      held 0, 0                held 0, 3        held 0, 0
```

After the fix: `u empty` reads `held 0, 3`; the other eleven cells are
unchanged.

## Control

`u truncated`: the same call, the same DATA frame position, the same
half-close; the frame carries 5 bytes of a gRPC prefix instead of none.
Held 0, answered 3. And the three other shapes with the same empty payload.
