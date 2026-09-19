---
round: 402
verdict: INCONCLUSIVE
packages: [rpc_dart_websocket, rpc_dart_http2]
lens: RPC-25
bench: P-88 — new
commit: yes
---

# Round 402 — the drain converges, for a reason nobody claimed

## Target

The sibling comparison P-87 named. `RpcHttp2Server._drain` sends GOAWAY before
polling, and its doc states why:

> That is the HTTP/2 signal for "no new streams here", and it is what makes a
> gRPC graceful shutdown CONVERGE rather than merely expire: without it a call
> issued after shutdown began is still accepted and served, extending shutdown
> by work that arrived after it started.

`RpcWebSocketServer._drain` has the same polling loop and no such signal,
because WebSocket has no GOAWAY. RPC-25: same duty, two implementations, one
missing a clause.

## Hypothesis

A client calling throughout `stop(drainTimeout:)` holds the websocket drain to
its whole budget while http2's converges, because only one of them can stop
admission.

## Before

P-88, new. Same client, same handler, same budget, one arm per transport:

```
lanes   transport   stop took   served before   served AFTER stop began
6       websocket      112 ms         321              70
6       http2            8 ms         285               6
64      websocket        5 ms         512              37
64      http2           36 ms         756              64
```

**Neither expires.** Both converge in milliseconds against a 3 s budget, and
the ordering between them FLIPS when the load changes — websocket is 14x slower
at 6 lanes and 7x faster at 64. A difference that reverses with load is not the
mechanism under test.

## Mechanism

`drainUntilIdle` samples an INSTANTANEOUS count. With 5 ms async handlers there
is always a moment when no responder is live, so both drains exit on the first
zero sample — before admission has anything to do with it. GOAWAY is not what
made either of these converge.

That makes the http2 comment a claim this round could not confirm. It is not
refuted either: a load with no gaps at all — long-lived streams rather than
unary calls — is where an admission stop would separate the two, and this bench
does not produce one. Round 321's variant of RPC-15 applies (a comment a
previous round wrote to explain its own fix, which nothing ages), but
establishing it needs a bench this is not.

## After

n/a — nothing changed, and nothing should on this evidence.

## Canary

n/a. The nearest thing is the load sweep itself, and it is what disqualified the
result: two load levels, opposite orderings.

## Gate

Not run: no library code changed. The round's only artefacts are two probes,
which live under `.dart_tool/probe/` and are outside analysis and the suite by
design.

## Why INCONCLUSIVE and not CLEAN

Config's rule: a bench that could not see the defect does not prove its absence.
This one demonstrably could not — it exits on a gap that its own load shape
guarantees. Calling it CLEAN would record "the websocket drain is fine" on
evidence that says only "both drains stop early for an unrelated reason".

Its first version was worse and is worth keeping as the reason the lanes exist:
a single sequential caller read **9 ms, 0 served after**, because one call at a
time leaves a gap at every sample.

## Not fixed

Nothing found. What a round taking this next needs is a load with NO gap —
server-streams held open across the drain, so `activeResponders` never reads
zero — and then the question "does the websocket drain expire where http2's
converges?" has an instrument. Filed as the probe's own limitation rather than
as a lead, because there is no defect to point at yet.

## Links

- RPC-25 — the lens; the sibling's doc is what framed the question
- P-88 — new, and honest about what it cannot see
- P-87 — round 401's probe, which named this comparison
