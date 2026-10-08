---
round: 725
verdict: CLEAN
packages: [rpc_dart_opentelemetry]
lens: RPC-22
bench: P-239 — new
commit: yes
release: none
---

# Round 725 — a peer cannot name a metric series

## Target

`rpc_dart_opentelemetry`, which five rounds in the journal touch. Its
interceptor labels spans and the `rpc.*.requests` / `rpc.*.duration` series
with `rpc.service` and `rpc.method`. RPC-22 asks what a peer reaches without
being accepted. Here: can a call to a method the server never registered,
whose name the peer chooses, mint a series?

## Hypothesis

The interceptor runs before method resolution, so each random name a peer
sends becomes one more span name and metric series. That is unbounded
cardinality in the SDK's aggregation.

## Before

Probe: `packages/core/rpc_dart_opentelemetry/.dart_tool/probe/r725_unknown_methods_reach_telemetry.dart`.
`OtelRpcInterceptor` on a responder with one registered method, spans
exported in memory.

```
  arm                                         spans
  CONTROL 100 calls to the registered method    100
  200 calls to unregistered names                 0
  distinct span names overall                     1
```

## Mechanism

The hypothesis does not hold. Interceptors wrap the handler chain of a
resolved method, and an unknown service or method is refused UNIMPLEMENTED
before that chain exists. Every label comes from the server's own registry.
The status attribute is bounded to 0..16.

## After

n/a — nothing to fix.

## Canary

n/a — no fix. The registered-method arm proves the instrument emits: 100.

## The verdict questions

1. Yes: only the method name differs.
2. Yes: 100 against 0.
3. Counted from the spans the SDK exported.
4. Zero, and the control arm shows the instrument emitting.
5. No fix, so no witness.
6. n/a.
7. CLEAN.
8. None.
A1. One endpoint pair; the caller is the peer.
A2. Neither.
L1. The refusal is UNIMPLEMENTED from method resolution, upstream of every
    interceptor.

## Gate

No library change.

## Not fixed

The client-side interceptor labels with names the application itself chose,
so a peer cannot drive it. Not measured.

## Links

Lens `../lenses/RPC-22-the-refusal-path-is-reachable-by-anyone.md` — `applied: [..., 725]`.
New bench `../probes/P-239-unknown-methods-against-the-otel-interceptor.md`.
