---
round: 828
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-19
bench: none — one probe, below; a CLEAN with a control
commit: yes
release: none
---

# Round 828 — a forwarded context carries only what the next hop needs

## Target

Network-audit `design` on round 805's `RpcContext.forward()`, against
rpc-design.md §9 ("hop-by-hop metadata, credentials and connection-specific
keys, is not forwarded by default") and §8 (deadline propagation). The
incoming context holds every request header the server received, the
incoming `grpc-timeout` among them; a forwarded copy of that next to the
new deadline would let the next hop read the longer one.

## Hypothesis

`forward()` carries the incoming `grpc-timeout` (or another
connection-specific header) as an ordinary header, so the next hop sees two
deadlines, or the parent's.

## Before

Probe `packages/core/rpc_dart/.dart_tool/probe/r828_forward_headers.dart`:
service A, called with a 30 s deadline, a trace id, `authorization` and
`x-tenant`, calls B with `context.forward(timeout: 1 s)`. B prints every
header it received and its remaining time. Control, B called directly with a
fresh 1 s context:

```
  direct:    remaining 974 ms; grpc-accept-encoding, grpc-timeout=984087u,
             x-request-id, x-route-service, x-trace-id
```

## Mechanism

n/a (CLEAN).

## After

```
  forwarded: remaining 999 ms; grpc-accept-encoding, grpc-timeout=999546u,
             x-request-id (new), x-route-service, x-tenant=t1,
             x-trace-id=trace-from-the-client
```

One `grpc-timeout`, the shortened one; `authorization` gone; the trace id
carried; the application's `x-tenant` carried, which §9 leaves to the
application.

## Canary

n/a, a CLEAN; the control is the same call made directly, which shows what
a fresh context sends and that B reports every header it receives.

## The verdict questions

1. The forwarded call against a direct one, same B.
2. No difference in the framework headers; the result is CLEAN.
3. At B, the next hop: its received headers and remaining time.
4. One call each; the headers are listed whole.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. none.
9. none.
10. No code changed.
A1. n/a. A2. n/a. L1. n/a.

## Gate

No code changed; the probe is outside the tree.

## Siblings

No code changed. `forward()` is core's and transport-agnostic.

## Not fixed

none.

## Links

Lens `../lenses/RPC-19-one-flag-two-lifecycle-meanings.md`. Round
`805-a-derived-context-cannot-outlive-its-parent.md`.
