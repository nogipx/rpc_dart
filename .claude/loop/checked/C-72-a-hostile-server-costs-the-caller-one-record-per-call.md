---
round: 797
commit: a8c7e4e6
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
scope: caller-side log records when the server answers unary calls with an over-limit, doubled or undecodable response
---

# C-72 — a hostile server costs the caller one record per call

The mirror of rounds 790-796 on the caller: a server answering every call
with an invalid response makes the caller write one ERROR per failed call
(two for an undecodable response), and the application gets the failure as
an exception each time (P-288).

Not the server-side defect, and why: on the server, the PEER chose how many
calls, so a record per call was a count the attacker set. Here the caller's
own application chose every call, and a server answering garbage is a
broken dependency, which an error records correctly. The second record for
an undecodable response is a duplicate report of one failure (round 515
named it), below the severity bar.

Re-open if a caller-side record ever fires on frames the server sends
without a call to answer (that count the server would choose); round 793
already makes the advisory case once per endpoint.

## Control

The `complete` arm: 0 records over the same 100 calls.
