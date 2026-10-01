---
round: 582
class: bench
cost: 1 probe rebuild and 1 extra ablation run, paid before the round concluded rather than after — but the counterfactual is what the cost is: a record graded `breaking` on 4 claims, 3 of which no peer could observe, and the one consequence a peer did have unrecorded
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http/.dart_tool/probe/b146_two_content_types.dart]
commit: a4c0297c
status: active
---

# L-18 — A lead that names one side of an adapter needs both

B-146 claimed two `content-type` values and prescribed its own instrument:
*"serve through shelf's test handler; inspect Content-Type values."* That is the
right instrument for what the code PRODUCES, and the lead was right that going
through a real server would measure the adapter instead. It was wrong that the
adapter's reading is therefore not needed.

Both, pre-fix:

```
HANDLER  application/grpc+json   2  [application/grpc+proto, application/grpc]
WIRE     application/grpc+json   1  [application/grpc]
```

**One view alone grades the lead wrongly, and in opposite directions.**

- HANDLER alone says: two values on every response, an interop defect, breaking.
  No `dart:io` peer has ever received two — that adapter keeps the last.
- WIRE alone says: one value, spec-legal, nothing here. It misses that the code
  really does build a list, which another host may emit, and it misses the only
  consequence a peer actually had: a `+json` caller was told `application/grpc`,
  because the value the lead was angry about (`+proto`) is the one the adapter
  threw away.

The rule: **when the claim is about what a peer sees and an adapter sits between
the code and the peer, the adapter is part of the subject, not noise to be
avoided.** Read the producing side to know what exists, and the receiving side to
know what it costs. Two readings in one probe, a row each, so neither can be
quoted alone — P-202.

This is `measurement.md` item 5 (*ask which SIDE the number was taken on*) turned
from a sanity check into a design rule: do not choose a side, instrument both.
Distinct from L-07, which is about hops INSIDE the library when behaviour
contradicts the code; here the behaviour and the code agree and the disagreement
is between two correct readings.

Corollary for the grading field: the release grade follows the WIRE row. A
duplicate no deployed adapter emits is not a break.
