---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/refusal_survives_a_tight_cap.dart
round: 216 — the validating round
commit: 10ba2a93
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/endpoint/**]
status: valid
---

# P-08 — does a refusal survive the policy it just enforced?

A real http2 server with `maxHeaderValueBytes` set tight, driven down three
paths that each make the server write a diagnosis longer than the cap: a method
nobody registered, round 208's un-consumed-window refusal, and then an ordinary
call to see whether the connection still works.

Run it with `melos exec --scope=rpc_dart_http2 -- fvm dart run
.dart_tool/probe/refusal_survives_a_tight_cap.dart`. The knob is the cap. To aim
it at another trailer, add a path that provokes that one.

## Measures

The gRPC status the CALLER ends up with, parsed out of the exception, plus
whether a plain call afterwards succeeds. The status is the whole point: the
lens's shape is the length of the explanation deciding what the client sees.

## Control

Three things, and the third is what makes it a bench.

1. **`maxHeaderValueBytes: 8192`** — the same paths with the cap out of the way.
2. **The plain call after** — a guard against the cap refusing ordinary REQUEST
   headers rather than the trailer. This is not hypothetical: at a cap of 16
   every row read status 3, including the plain call, because rpc_dart's own
   headers do not fit (a request-id UUID alone is 36 bytes). No row there can be
   attributed to the trailer. 64 is the lens's own number and leaves ordinary
   traffic untouched.
3. **An ablation** — the `maxMessageLength` argument removed from the
   `_fcRefuseOverrun` trailer.

```
  cap    unimplemented   un-consumed window   plain call after
  8192   status 12       status 8             ok
    64   status 12       status 8             ok
    16   status 3        status 3             status 3     <- confounded
    64   status 12       ArgumentError        ok           <- ablated
```

The ablated row is the evidence that the bench sees this defect: one trailer
losing its cap turns a clean RESOURCE_EXHAUSTED into a raw `ArgumentError` at
the caller.
