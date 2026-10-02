---
round: 621
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-223 — new
budget: probes 1/5, canaries 0/5
commit: yes
release: none
---

# Round 621 — the copies are five percent

## Target

B-120's last half. Each `with*` copies both context maps, `withAdditionalHeaders`
re-runs the header regex, and `forClientRequest` runs two regexes. The lead
asked for the chain a real call builds, not a synthetic one.

## Hypothesis

The context copies and header validation are a visible share of a unary call.

## Before

```
127.1 us per call
 28.1%  RpcContext._uniqueToken (inside withTracing, 29.2%)
  1.4%  RpcContext._        1.4%  withHeaders        1.1%  _sanitizeHeaders
  0.7%  forClientRequest    0.7%  _validateMethodToken
  <=0.4% each for the remaining context and metadata helpers and _RegExp
```

`P-223`, VM profiler samples over 3000 real unary calls.

## Control

The token, whose cost earlier rounds established, appears at its known share.

## Mechanism

Everything the lead's remaining half names together comes to about 5 % of a call.
The token is the cost on this path, at 28 %, and the owner kept it in the
round-565 review. Persistent maps for the context would remove part of 5 %, and
the rewrite would touch the type every handler receives.

## After

n/a — no change.

## Canary

n/a — no fix.

## Gate

Not run: no change to `lib/` or `test/`.

## Not fixed

Nothing in B-120. The `base_processor.dart` null-context branch named from
round 566 builds an `RpcContext.empty()` that `RpcCallerEndpoint` never reaches,
and it is inside the same 5 %.

## Links

Lead `../backlog/B-120-per-call-context-and-id-cost.md` — closed.
Bench `../probes/P-223-what-a-real-call-spends-on-context.md` — new.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [..., 621]`.
