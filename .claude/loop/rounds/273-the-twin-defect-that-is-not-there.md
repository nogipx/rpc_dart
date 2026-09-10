---
round: 273
verdict: CLEAN
packages: [rpc_dart_http]
lens: RPC-14
bench: P-24 — new
commit: yes
---

# Round 273 — the twin defect that is not there

## Target

B-26, filed one round earlier and the only lead in the backlog that was both
open and cheap. Round 272 had to learn, at the cost of a canary, that
`.timeout()` on a future does not cancel the subscription feeding it — and the
accepted path uses exactly that construct one screen above the one just fixed.
Taking it immediately rather than letting it age was the point: a lead written
from code-reading is a hypothesis, and this one looked certain enough to be
worth refuting fast.

Lens RPC-14 — a timeout that drops the wait but not the work — applied to a site
its sweeps had never covered.

## Hypothesis

After `bodyReadTimeout` fires and the 408 goes out, `readBody`'s `await for`
keeps consuming whatever the peer sends, forever, on a stream nobody counts any
more.

## Before

One socket promises 16 MiB, sends five bytes, waits for the answer, then writes
64 KiB chunks as fast as the server takes them with every flush deadlined at 3s.

```
arm      bodyReadTimeout  status           the server took       pendingRequests
reading  none             NEVER ANSWERED   16384 of 16384 KiB    1
                                           in 49 ms
timeout  500ms            408               384 KiB, then a      0
                                           3s stall
```

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/read_after_the_408.dart`

384 KiB is the socket's own buffering and reproduced exactly on two runs. The
hypothesis is **refuted**: the read stops.

## Mechanism

Not in this code. `_reject`'s drain — round 272's fix — subscribes to a request
body that nothing else will ever end, so only an explicit cancel bounds it.
`readBody`'s subscription is on a request whose response completes a moment
later, and dart:io detaches the body of a finished exchange. The loop is ended
by the layer below rather than by the timeout.

## After

n/a — nothing changed.

## Canary

n/a. The `reading` arm is what carries the meaning here: the same bench, same
writes, takes all 16 MiB in 49 ms against a server that IS still reading, so the
stall in the other arm is a property of the server rather than of the probe.

## Gate

n/a — no code changed. `loop.py lint` green.

## Not fixed

Nothing to fix. B-26 closes as refuted, and its content becomes negative C-31 so
the next round to read those two `.timeout(` sites side by side does not
re-derive the same wrong prediction.

## Links

RPC-14 (`applied:` gains 273; its sweep status is untouched — this is one site,
not a re-sweep). Bench P-24, new. B-26 closed. C-31, new. Round 272 is what
produced the lead.
