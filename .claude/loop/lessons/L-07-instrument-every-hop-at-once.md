---
round: — (pre-201, off-journal; imported in the curate pass after 234)
class: bench
cost: 3 of 4 attempts at per-stream flow control lost to diagnosing by argument, each redesigning around a cause that was never verified; 2 further repeats in the same feature
paths: [packages/core/rpc_dart/lib/src/**, packages/transport/*/lib/**]
commit: d9b96a67
status: active
---

# L-07 — Instrument every hop at once; do not reason about which one is wrong

Per-stream flow control took four attempts. Three were spent arguing about the
cause — first "a pause-count imbalance", then "credit-on-delivery makes pause
propagation irrelevant" — and each isolated hop was confirmed to propagate pause
correctly, including three nested `async*` generators, so the model said it must
work. It didn't. One counter per hop, printed with the consumer paused, found it
in minutes: exactly one controller was missing an `onPause`, and everything
upstream drained regardless.

**When behaviour contradicts what the code appears to say, add a counter at
EVERY hop simultaneously and diff the snapshot around the state change** — a
temporary `Map<String,int>` in `lib/src/core/transport.dart` (imported by every
layer) with a `rpcTick(key)` at each hop, stripped before committing.

Two corollaries the same feature paid for twice more. **Measure what the library
PULLS, not what your fixture produced**: counting `produced` (handler output) or
`sent` (pushes into a local `StreamController`) measures the app's own unbounded
buffer, not the library's. To see what is actually pulled from a request stream,
feed it an `async*` generator directly — never a `StreamController` you push
into, which accepts unboundedly whatever the consumer does.
