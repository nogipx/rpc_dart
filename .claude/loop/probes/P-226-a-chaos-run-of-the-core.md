---
file: packages/core/rpc_dart/.dart_tool/probe/chaos_core.dart
round: 640
commit: d887a27d
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart, packages/core/rpc_dart/lib/src/resilience/circuit_breaker_interceptor.dart, packages/core/rpc_dart/lib/src/resilience/rate_limiter.dart]
status: valid (round 640)
---

# P-226 — a chaos run of the core

## Why it exists

Fuzzing (P-225) reaches what a peer's bytes can do. Lifecycle defects -- a
call settled twice or never, a slot or responder left behind -- come from
timing between many calls, which no single-path test drives.

## The harness

`fvm dart run packages/core/rpc_dart/.dart_tool/probe/chaos_core.dart
[epochs] [seed] [pair|memory] [resilience]`. Each epoch: a fresh transport
pair, a responder with all four shapes, 200 calls fired at once. Handler
behaviour comes from the request text: `ok`, `delay` (checks its token),
`deaf` (ignores it), `throw`, `status`, `unavailable`, `flood`, `partial`
(stops reading), `yield-throw`. Caller chaos: a cancel at a random time, a
random deadline, abandoning a stream after a few messages, a request stream
that throws. One epoch in six closes the server transport mid-traffic.
`resilience` adds a retry interceptor, a circuit breaker and a rate limiter
to the caller.

## The numbers (round 640)

```
channel pair, 10 + 60 epochs    14 000 calls  hung 0  settled twice 0  responders left 0  zone 0
in-memory, 30 epochs             6 000 calls  hung 0  settled twice 0  responders left 0  zone 0
pair + resilience, 15 epochs     3 000 calls  hung 0  settled twice 0  responders left 0  zone 0
RSS across epochs: flat or falling (e.g. 246 -> 105 MiB over 60 epochs)
```

## Measures

Whether concurrent calls under chaos keep the lifecycle invariants.

## Control

The `ok` handlers with no caller chaos return values; outcome counts per run
show every status class the chaos produces, so a run that never reached an
arm would show it.
