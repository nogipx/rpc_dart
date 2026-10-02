---
status: open
round: 625
commit: ff258470
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/responder.dart]
probe: none — audit probes `packages/core/rpc_dart/.dart_tool/probe/correct_wire_foreign_server_test.dart`, `correct_wire_foreign_client_test.dart`, not yet registered
reason: "decision — two responses on unary or client-stream report success (unary keeps the first, client-stream the last), and a second request on unary or server-stream is dropped; gRPC fails such a call"
---

# B-235 — a second message on a single-message side is accepted

Found by the independent audit of 2026-10-02 (protocol), reproduced before
filing.

## Measured

```
two responses + OK      unary VALUE one      clientStream VALUE two
control, one response   unary VALUE one      clientStream VALUE one
server: unary, two requests        DATA [a], status 0 (second dropped)
server: server-stream, two         DATA [a], status 0
```

grpc-go fails the call INTERNAL ("cardinality violation"), grpc-java likewise.
Round 623 made unary keep the first and warn once (B-129 item 16); the two
caller shapes still disagree with each other.

## The question for the owner

Fail such a call (INTERNAL, as gRPC does), or keep accepting it and only make the
two callers agree on which message stands.

## Owner decision

—
