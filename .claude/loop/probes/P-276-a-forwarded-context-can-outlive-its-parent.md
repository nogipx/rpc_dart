---
file: packages/core/rpc_dart/.dart_tool/probe/deadline_extension.dart
round: 781
commit: 2f469332
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart]
status: valid
---

# P-276 — a forwarded context can outlive its parent

## Measures

Two `RpcChannelTransport.pair()` rigs: client -> A -> B. The client calls A
with `RpcContext.withTimeout(200ms)`. A's handler forwards to B with one of
four contexts built from its incoming one. B waits 3 s or until its
`cancellationToken` fires, and prints the `remainingTime` it was given and how
long it ran.

```
  arm                      B told     B ran     B ended
  createChild()            175 ms     191 ms    cancelled
  createChildWith(2s)      1998 ms    199 ms    cancelled
  withTimeout(2s)          1999 ms    199 ms    cancelled
  sanitize(ctx)            none       3003 ms   finished
```

The client got DEADLINE_EXCEEDED at about 200 ms in every arm.

## Control

`createChild()`: the same forwarding with the parent's deadline left alone.
B is told 175 ms and stops at 191 ms. The only thing varied in the next two
arms is the timeout argument, and B's deadline goes from 175 ms to 2 s. In
those arms B still stops at about 200 ms because the parent's token is
inherited and A's responder cancels it at A's deadline; the work is bounded
by delivery of the cancel, not by the deadline B was given.
