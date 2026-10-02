---
status: open
round: 625
commit: ff258470
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart]
probe: none — audit probe `packages/core/rpc_dart/.dart_tool/probe/correct_wire_foreign_server_test.dart` (garbage body), not yet registered
reason: "bench — a response the codec cannot decode reaches the caller as a raw FormatException, not an RpcStatusException(INTERNAL); the server maps the same failure on a request to 13"
---

# B-236 — an undecodable response has no status

Found by the independent audit of 2026-10-02 (protocol), reproduced before
filing.

## Measured

```
garbage body    unary        ERR FormatException: Expected map, got major type: 7
                clientStream same
server side, undecodable request    grpc-status 13
```

A caller that catches `RpcException`, as the error-handling guide shows, does
not catch it, and status-keyed interceptors (retry, breaker) see no status.

## Owner decision

—
