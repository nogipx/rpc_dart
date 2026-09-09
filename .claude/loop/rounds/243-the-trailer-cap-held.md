---
round: 243
verdict: CLEAN
packages: [rpc_dart, rpc_dart_http2, rpc_dart_http, rpc_dart_websocket]
lens: RPC-02
bench: none
commit: no
---

# Round 243 — the trailer cap held

## Target

RPC-02, `swept here (round 216, 10ba2a93)`, with ten files moved under its paths
since — the largest remaining drift now that RPC-13 has been re-swept. Round 237
is the reason it was worth re-running rather than trusting: it added a REFUSAL
to the http2 inbound header walk, and this lens is precisely about whether a
refusal's own explanation survives the policy that refused.

Passed over: RPC-06 still needs a booted device; the three leads filed in 240
and 241 wait on the owner or on an hour of cycles.

## Hypothesis

Code added since 10ba2a93 assembles a trailer without a cap, on a path that
validates it — so the length of a diagnosis decides the status again, or an
inbound trailer kills the connection.

## Before

```
files moved under the lens's paths since the sweep   10
trailer assembly sites reachable from them           16
sites passing a `message:`                           12  all carry maxMessageLength
sites passing no message                              4  always fit
sites with an uncapped message on a validating hop     0
```

No bench: the detector yields a finite list and the question is answered by
reading each site, which is what the lens's own "which sites to actually look
at" section prescribes.

## Mechanism

n/a — nothing found.

## After

n/a

## Canary

n/a

## Gate

Nothing shipped, so the gate is the previous round's: the tree at 0a6e25d5 is
green across `analyze`, `test:unit`, `format:check` and `license:check`.

## Not fixed

Nothing found to fix. Two things this sweep did NOT establish, both worth saying
so the next round does not read more into it:

- **It is a reading, not a measurement.** Round 216 backed its clean result with
  an ablation — dropping the cap from one trailer turned status 8 into a raw
  `ArgumentError` — and this round did not repeat that. What it checked is that
  every site still passes the cap, which is the property the ablation gave
  meaning to.
- The **two new refusal paths** added since (round 237's header-block refusal in
  `rpc_http2_common.dart`, round 240's `_fcRefuseOverrun`) both report through
  `sendMetadata` with `maxMessageLength: _policy.maxHeaderValueBytes` and both
  guard the send with `.catchError`. That is the shape the lens asks for, in new
  code, without the lens having been consulted — which is the outcome a lens is
  for.

## Links

Lens RPC-02, re-swept: status moves to `swept here (round 243, 0a6e25d5)` ·
the shape it refines is catalog U-09 · the sites this round re-read are the ones
its "which sites the detector should actually look at" section names.
