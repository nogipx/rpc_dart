---
file: packages/core/rpc_dart/.dart_tool/probe/r743_two_closes_on_a_stuck_handler.dart
round: 743
commit: a94aca2c
paths: [packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/contracts/call_scope.dart]
status: valid
---

# P-247 — do two concurrent responder close() calls finish while handlers hang?

One call of each shape (unary, server stream, client stream, bidi) is open
on a `RpcChannelTransport.pair()`. In the stuck arm each handler registers a
call-scope disposer that never completes, and the unary, server-stream and
bidi handlers park at an `await` that never completes. Then two
`responder.close()` calls run at once, each capped at 15 s. Run with
`fvm dart run .dart_tool/probe/r743_two_closes_on_a_stuck_handler.dart` in
`packages/core/rpc_dart`. Pass `unbounded` for the ablation.

## Measures

The time each close() takes to return, or HUNG at 15 s.

## Control

The healthy arm: the same four calls with handlers that do not hang. The
ablation sets `RpcCallScope.disposerTimeout` to 1 h, and both closes then
hang. The process keeps running on those timers, so stop it by hand.
