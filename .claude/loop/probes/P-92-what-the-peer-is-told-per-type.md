---
file: packages/core/rpc_dart/.dart_tool/probe/what_the_peer_is_told_per_type.dart
round: 408
commit: 566ad1cb
paths: [packages/core/rpc_dart/lib/src/core/protocol.dart, packages/core/rpc_dart/lib/src/core/errors.dart, packages/core/rpc_dart/lib/src/contracts/context.dart]
status: valid
---

# P-92 — what a handler's error TYPE costs the peer

## Why it exists

`wireStatusFor` is DEFAULT DENY: only `RpcStatusException` and rpc_dart's own
`RpcException` hierarchy reach a peer intact, everything else is redacted to
INTERNAL(13) "Internal server error". Three library types sat outside that
hierarchy. Its doc said that cost nothing; this asks.

## Measures

The `grpc-status` and `grpc-message` a caller receives, one unary method per
error type, over a real websocket.

## Control

Three of the five arms ARE controls, and they are what make the subjects
readable:

```
rpcException     inside the hierarchy      -> the message must survive
statusException  the supported way to speak -> status AND message must survive
stateError       foreign                   -> must be redacted
```

Without them, "the subjects come back INTERNAL" and "everything comes back
INTERNAL" are the same output. With them, the mechanism is named: outside the
hierarchy, default deny.

The third is also the GUARD for any future widening — if `stateError` ever
stops being redacted, the deny has been broken.

## The numbers (round 408)

```
                  before                          after
cancelled         13 "Internal server error"      1  "handler cancelled"
deadline          13 "Internal server error"      4  "Deadline ... exceeded"
rpcException      13 "RpcException: a library diagnostic"   unchanged
statusException    5 "no such shape"                        unchanged
stateError        13 "Internal server error"                unchanged
```

## What it establishes, and what it does not

Establishes: a handler throwing `RpcCancelledException` was indistinguishable
from one throwing a foreign `StateError`, and the fix at the TYPE (extending
`RpcStatusException`) changes the subjects while leaving every control exactly
where it was — which is the evidence that the deny was not widened.

Does not drive the transports' own types (`RpcHttp2StreamError`,
`RpcWebSocketNonBinaryFrame`), nor the 83 raw `StateError` / `ArgumentError`
sites, which need a reachability split first: programmer error versus a runtime
condition a peer can cause.
