---
file: packages/core/rpc_dart/.dart_tool/probe/r732_second_close_returns_early.dart
round: 732
commit: 12d8af9f
paths: [packages/core/rpc_dart/lib/src/endpoint/base_endpoint.dart, packages/core/rpc_dart/lib/src/endpoint/caller_endpoint.dart, packages/core/rpc_dart/lib/src/endpoint/responder_endpoint.dart, packages/core/rpc_dart/lib/src/endpoint/peer_endpoint.dart]
status: valid
---

# P-243 — does a second concurrent endpoint close() wait for the first?

A caller endpoint over a transport decorator whose `close()` takes 200 ms,
closed twice concurrently. Run with `melos exec --scope=rpc_dart -- fvm dart
run .dart_tool/probe/r732_second_close_returns_early.dart`.

## Measures

When each `close()` returns, and whether the transport was closed when the
second one did.

## Control

The first call, which always waits:

```
  before r732   first 210 ms; second 6 ms, transport closed: false
  after r732    first 209 ms; second 209 ms, transport closed: true
```
