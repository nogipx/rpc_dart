---
status: open
round: — (not re-measured by a round; measured by the conformance matrix)
commit: 91ec33ea
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**, packages/core/rpc_dart/lib/src/endpoint/**]
probe: none — packages/test/rpc_dart_conformance/test/i5_resources_return_test.dart, the KNOWN FAILING channel and isolate cells
reason: bench — KNOWN FAILING cells of I-5 and of the lifecycle model; severity S1, the residue grows by one entry per call
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
for other endings.

**It grows per call.** The lifecycle model (`test/lifecycle_model_test.dart`)
shrinks seven isolate seeds to ONE call each, and two such calls leave 2:

```
start serverStream echo delay=0 count=2 deadline=65
  -> server fc.sendCredit / fc.messageCredit / fc.advertised 0 -> 1
answering at once, failing, or ending by deadline: residue
answering after 30 ms or 300 ms: clean (why the I-5 "completes" cell passes)
channel and isolate, bidi paused + half-close + cancel: fc.advertised 0 -> 1
```

A long-lived connection accumulates it, so S1. The model ignores `fc.*` on
channel and isolate until this closes; the I-5 rows still catch it.

## Owner decision

—
