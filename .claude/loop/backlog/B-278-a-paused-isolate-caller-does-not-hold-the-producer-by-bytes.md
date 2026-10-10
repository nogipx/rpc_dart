---
status: open
round: — (not re-measured by a round; measured by the conformance matrix)
commit: 91ec33ea
paths: [packages/transport/rpc_dart_isolate/lib/**, packages/core/rpc_dart/lib/src/rpc/transports/**]
probe: none — packages/test/rpc_dart_conformance/test/i3_memory_per_peer_test.dart, cell "isolate | server stream, caller paused"
reason: bench — a KNOWN FAILING cell of I-3; severity S1 (memory a paused caller lets grow)
rank: 2
---

# B-278 — a paused isolate caller does not hold the producer back by bytes

Found by the conformance matrix (I-3, memory per peer is bounded).

Under one policy, a server-stream handler keeps producing past a paused caller:

```
the handler produced 172 messages of 16384 bytes past a paused caller;
the policy bounds it near 104
channel, websocket under the same policy: 33
isolate, 1 KiB messages: plateaus at 8193; larger runs to the row's 4000 cap (64 MiB)
```

On isolate the byte window does not hold the producer back; only the message
limit does. B-106 (closed, round 550) gave zero-copy transports backpressure;
this is the byte half of it, on the one sibling where it is missing.

## Owner decision

—
