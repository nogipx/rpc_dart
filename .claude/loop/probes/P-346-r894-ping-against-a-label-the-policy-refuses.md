---
file: packages/core/rpc_dart/.dart_tool/probe/r894_ping_label/probe.dart
round: 894
commit: aebe20ff
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_ping_handler.dart, packages/core/rpc_dart/lib/src/endpoint/ping.dart]
status: valid
promoted: packages/core/rpc_dart/test/endpoint/a_ping_answers_whatever_the_endpoint_is_called_test.dart
---

# P-346 — r894 ping against a label the policy refuses

## Measures

The outcome of one `caller.ping()` over an in-memory pair to a responder
built with a given `debugLabel`. Arms: "Сервер заказов" and 10000 x "a".
Before: both `RpcStatusException(3): Invalid metadata header value for:
x-rpc-pong-endpoint`. After: both ok, the label 14 and 1024 characters (the
encoder's length cap).

## Control

"orders" and no label: ok before and after.
