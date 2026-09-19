---
round: 407
verdict: CLEAN
packages: [rpc_dart_isolate]
lens: RPC-25
bench: P-91 — new
commit: yes
---

# Round 407 — the third row

## Target

The isolate transport, the owner's second-priority one and untouched for many
rounds. Round 405 measured what a caller is told when its peer is gone on
websocket and http2 and found the two disagree; the owner has since asked for
one shape across ALL transports. The third one had no row.

It is also the transport that fits neither side of that comparison: no
`_disconnected`, no `reconnect()`, and a lifecycle that is just
`spawn() -> (transport, kill)`.

## Hypothesis

A worker that dies without being killed is the isolate's version of the gap —
the host learns nothing and a caller hangs.

## Before

Refuted by reading before a line was run, which is the cheap half.
`spawn()` registers an errorPort AND an exitPort, and after startup both do the
same thing: `unawaited(hostChannel?.close())`. So the host is told on both
paths, and the remaining question is what that means to a CALLER, and whether
the two deaths look alike.

P-91, new, three arms — an uncaught throw (errorPort), a self-kill (exitPort),
and the host's own `kill()`, which reaches neither:

```
mode    first        in flight               isClosed   a later call
throw   served(ok)   RpcStatusException(14)  true       RpcStatusException(14)
exit    served(ok)   RpcStatusException(14)  true       RpcStatusException(14)
kill    served(ok)   -                       true       RpcStatusException(14)
```

Consistent on all three. A call already in flight when the worker dies is
answered UNAVAILABLE rather than left hanging, including the awkward case: an
uncaught error thrown from a TIMER, after the handler's own frame is gone, so it
reaches `errorPort` instead of becoming an ordinary call error.

## Mechanism

n/a — nothing is broken. Worth recording why `isClosed: true` is not a fourth
disagreement: a killed isolate is terminal, there is nothing to reconnect to,
and the remedy is to spawn another. The socket transports stay `false` because
they can recover. Same column, different correct answer, because the state
model genuinely differs.

## After

n/a — no change.

## Canary

n/a — no fix. `kill` is the control on the other two arms: it reaches neither
port, so a different answer there would have been attributable to the port
rather than to the death. It gives the same one.

## Gate

Not run: no library code changed. The only artefact is a probe, outside
analysis and the suite by design.

## Not fixed

Nothing found. The table now reads, for a peer that is gone:

```
transport   isClosed   a later call
websocket   false      RpcStatusException(9)    FAILED_PRECONDITION
http2       false      RpcStatusException(14)   UNAVAILABLE
isolate     true       RpcStatusException(14)   UNAVAILABLE
```

**This round does not decide anything with that**, because the question of which
status wins is an unanswered one put to the owner. It is a row, not an argument:
two of three say UNAVAILABLE today, and the third transport has no `reconnect()`
for a message to point at. Recorded in the lead for whoever carries the decision
out.

## Links

- P-91 — new
- RPC-25 — the third sibling of a comparison two rounds old
- Round 405 — which built the first two rows
