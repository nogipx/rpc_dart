---
file: packages/core/rpc_dart/.dart_tool/probe/parked_waiters_drain.dart
round: 211 — the validating round
commit: 0d071c55
paths: [packages/core/rpc_dart/lib/src/rpc/transports/**]
status: stale (0d071c55) — channel_transport.dart changed since; repeat the control before reusing
---

# P-04 — does an abandoned upload leave its sender parked?

Endpoints over `RpcChannelTransport.pair()`, a 64 KiB window, and a
client-stream handler that consumes NOTHING and answers after 400 ms. The client
offers 8 MiB per call, so it fills the window and genuinely parks at 17 messages
(68 KiB) before the answer arrives. Thirty such calls, reading
`flowControlStateSizes` after each.

Run it with `melos exec --scope=rpc_dart -- fvm dart run
.dart_tool/probe/parked_waiters_drain.dart`. The `drains` flag is the control.
It reads every counter in the map, so it serves any question about per-stream
bookkeeping surviving teardown, not just the waiters one.

## Measures

`flowControlStateSizes['waiters']` — `_fcSendWaiters.length`, one entry per
stream with a parked sender — after each call and at the end. Public precisely
because it is peer-keyed bookkeeping. `sendCredit` is read alongside it and is
what surfaced B-14.

## Control

Two of them, and both are needed:

1. **A handler that DRAINS**, so the sender never parks at all. Distinguishes
   "teardown releases the sender" from "the sender was never held".
2. **The ablation**: remove `_fcWake(streamId)` from `_fcForget`. This is what
   proves the bench can see the defect — round 210 could not make that claim
   about its own probes and therefore refused to register them.

```
                                  waiters   sendCredit
  handler drains                     0          0
  handler consumes nothing           0         30      <- B-14
  same, _fcWake ablated             30          0
```

30 is the call count, so both non-zero figures are exactly one entry per call.
Note the ablated row also drops sendCredit to 0: the stale credit entry only
appears when the sender is WOKEN, which is what makes B-14's mechanism a
re-entry into `_fcTryConsume` rather than a plain failure to clean up.
