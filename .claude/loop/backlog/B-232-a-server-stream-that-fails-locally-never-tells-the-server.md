---
status: closed (round 626)
round: 626
commit: afc045e6
paths: [packages/core/rpc_dart/lib/src/rpc/streams/server/caller.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: none — audit probes `packages/core/rpc_dart/.dart_tool/probe/correct_shapes_b.dart`, `correct_shapes_c.dart`, `correct_shapes_h.dart`, not yet registered
reason: "FIXED in round 626: any ending the server did not cause sends the abort notice before close(); two failed streams under a limit of 2 now leave 0 live handlers. Previously: bench — a server-stream call that fails on the caller side (response decode, response middleware) sends nothing to the server; the handler keeps producing and holds its slot"
---

# B-232 — a server-stream that fails locally never tells the server

Found by the independent audit of 2026-10-02 (semantics), reproduced before
filing.

## The shape

`ServerStreamCaller.call()` ends with `close()`, which closes the local scope
only. The peer is told only through the cancellation token, and
`_bridgeCallerResponses` fires it on a consumer cancel, not when the source ends
in an error. Client-stream (`notifyPeerOfAbort`) and bidi (`cleanup(abortPeer:
true)`) both tell the peer on a local failure; server-stream has neither.

## Measured

```
decode fails     server produced 2 -> 155 two seconds later, handler not cancelled, activeResponders 1
bidi, same       server produced 2 -> 3, handler cancelled, activeResponders 0
maxConcurrentHandlers 2, two failed streams, next unary -> status 8
control: the consumer breaks after 1 message -> activeResponders 0, next unary served
```

## Fix direction

The sibling shapes' pattern: on a local error the caller sends the cancel to the
peer before closing.

## Owner decision

—
