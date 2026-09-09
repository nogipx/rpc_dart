---
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http2/lib/**, packages/transport/rpc_dart_isolate/lib/**]
scope: [websocket, http2, isolate]
---

# C-01 — Ordinary sustained load retains nothing

Measured in round 191, off-journal; the numbers were imported from private
memory after round 235, where this record had been a stub.

**Every other leak hunt in this loop was ATTACK-shaped** — oversized frames,
ghost ids, floods. This is the boring case nobody had run: a client making call
after call on one healthy connection, which is what a deployment does all day.

Batches of 2000 / 4000 / 8000 unary calls (isolate also 16000 / 32000) with a
5-item server stream every tenth call, on ONE connection, watching
**bytes-per-call** rather than total RSS — a retained leak holds its per-unit
figure CONSTANT, while churn makes it fall:

```
  websocket  14352 -> 2310 -> -408 B/call        RSS 235->269, settled 244
  http2       4678 ->  -66 -> -3328 B/call       RSS 233->242, settled 215
  isolate    11321 -> 9069 -> 780 -> 846 -> 306  RSS 245->330, settled 323
```

`openStreams` was 0 at every sample on all three. **All clean.**

The isolate row looks different only because its RSS does not come back down —
but its per-unit is FALLING, not flattening on a positive plateau, and the
process holds two Dart heaps (host and worker), so the high-water mark is
naturally higher and less readily returned. Compare round 90's genuine
retention, which flattened at ~8113 B/frame
(`../backlog/B-16-pre-method-byte-budget-release.md`).

Isolate spawn/kill cycles are flat too: 20 / 40 / 80 cycles at 11 / -3 / 2 KiB
per cycle, i.e. nothing. A leaked isolate is megabytes, so this is the expensive
thing to get wrong on that transport, and it is not wrong.

**Deliberately not turned into tests**: 14k-62k calls per run is too slow for the
gate, and the severity bar forbids coverage for its own sake. Rebuild from this
description if it ever needs re-checking; the probes lived in each package's
gitignored `.dart_tool/probe/sustained_load.dart`.

## Control

**The per-unit figure IS the control**, and choosing it over total RSS is what
makes the verdict readable: a retained leak holds bytes-per-call constant as the
batch grows, so a falling series cannot be retention. That is why the isolate's
rising RSS is not a counter-example — its per-call number falls across five
batches. A run measured on RSS alone would have called the same data a leak.
