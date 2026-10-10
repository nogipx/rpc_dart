---
status: open
round: — (not re-measured by a round; measured by the conformance matrix)
commit: 91ec33ea
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**, packages/core/rpc_dart/lib/src/endpoint/**]
probe: none — packages/test/rpc_dart_conformance/test/i5_resources_return_test.dart, the KNOWN FAILING channel and isolate cells
reason: bench — KNOWN FAILING cells of I-5; severity S2 until the leak is shown to grow per call
rank: 3
---

# B-279 — flow-control credit stays on the server after some endings

Found by the conformance matrix (I-5, resources return).

The server side of `RpcChannelTransport` keeps flow-control state after a call
has ended in these ways:

```
isolate unary deadline, isolate serverStream deadline, isolate bidi handlerFails,
40 calls on one connection (channel, isolate):
server gauges not back at baseline: still
{fc.sendCredit: 0 -> 1, fc.messageCredit: 0 -> 1, fc.advertised: 0 -> 1} after 2000 ms
```

Core's `flow_control_state_returns_to_zero_test` pins the same bookkeeping
for other endings. The first measurement a round owes: does the residue grow
with the number of such calls (S1) or stay at one unit (S2)?

## Owner decision

—
