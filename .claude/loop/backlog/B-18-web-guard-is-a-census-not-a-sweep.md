---
status: open
round: 219
commit: 201a2034
paths: [packages/transport/rpc_dart_websocket/lib/**, packages/transport/rpc_dart_http/lib/**, packages/data/**, packages/blob/**]
probe: —
reason: owner approved the cost (round 223) — take it; plant a bug class and find out what the web gate actually catches
---

# B-18 — the web guard is a census, not a sweep

Round 219 counted what `melos run test:web` runs. Three packages run their whole
suite on dart2js — core, compression, reflection. Nine contribute between one
and six hand-written smoke tests, because the rest of their suites bind sockets
and spawn servers and node cannot.

That guard catches "this package no longer builds for JS", which is what it was
written for. It was never shown to catch the bug classes RPC-07 is about.

## What to do

Ablate, the way rounds 214-216 did. Pick one class and plant it in a
web-reachable path in a smoke-only package, then run the gate and see whether
anything goes red:

- an int above 2^53 in a length or id;
- `async*` cancellation, which deadlocks on dart2js;
- clock resolution, where `DateTime.now()` is coarser on JS;
- `Random.secure`, unavailable in some JS contexts;
- a VM-only codec reached from a shared path.

Whatever survives undetected names the gap precisely, and the fix is a smoke
test for that class rather than a general plea for more coverage.

Do NOT start by widening the suites: most of what is missing genuinely cannot
run on node, so the answer is targeted smoke tests, and this measurement is what
says which ones.

## Owner decision

**Take it — the cost is approved.** (Asked and answered in round 223.)

Start with `async*` cancellation. Of the five candidate classes it is the one
with a confirmed history on this project (the dart2js cancel-deadlock in private
memory), so a plant that survives undetected is a gap in a class known to
occur here rather than a hypothetical one. Do the int-above-2^53 class second if
budget allows.

Every plant is reverted in place, per rounds 214-216 — `git diff` empty before
the verdict is written.
