---
round: 205
verdict: CLEAN
packages: [rpc_dart_websocket, rpc_dart_isolate]
lens: RPC-08
bench: none
budget: probes 0/3, canaries 0/3
review: self (record migrated into the schema; the round itself had no review)
commit: no
---

# Round 205 — DoS limits really do bite on the channel transports

## Target

RPC-08 (a policy field checked on one transport only) plus U-21. Round 119 found
`maxConcurrentHandlers` working on http2 and DEAD on HTTP/1.1; round 193 only
checked that every policy field was MENTIONED somewhere. Neither proved the
limits bite on the channel transports.

## Hypothesis

`maxConcurrentHandlers` and `halfOpenStreamTimeout` are inert on websocket and
isolate, the way they once were on HTTP/1.1.

## Before

```
maxConcurrentHandlers — peak concurrent handlers,
each one held for 900 ms:

  websocket, no ceiling, 30 calls -> peak 30   <- control
  websocket, ceiling 3,  30 calls -> peak 3
  websocket, ceiling 1,  10 calls -> peak 1
  isolate,   no ceiling, 30 calls -> peak 30   <- control
  isolate,   ceiling 3,  30 calls -> peak 3

halfOpenStreamTimeout — 20 streams opened by a single metadata
frame, openStreams polled until the deadline:

  timeout off  -> 20 parked, still 20 after 20 s   <- control
  timeout 3 s  -> 20 parked, then 0
```

Probes: `handler_ceiling.dart` (websocket and isolate), `half_open_reclaim.dart`
(websocket).

## Mechanism

The hypothesis did not hold. Both limits work. `halfOpenStreamTimeout` defaults
to 60 s rather than null, so half-open streams are reclaimed out of the box; the
timeout-off row above is a probe that deliberately removed the bound, and it is
easy to misread as "it leaks by default".

## After

n/a

## Canary

n/a — the no-ceiling rows are the control: without them a bench that fails to
reach concurrency would have shown "3" and looked like a working limit.

## Gate

n/a — no edits

## Not fixed

Nothing

## Links

Lens `../lenses/RPC-08-policy-field-single-transport.md` — status updated,
websocket and isolate closed. No negative was filed in `checked/`: this is a
sweep by a lens detector, and its home is the lens status.
