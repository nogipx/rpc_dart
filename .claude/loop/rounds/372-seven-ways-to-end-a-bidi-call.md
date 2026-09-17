---
round: 372
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-05
bench: P-63 — new
commit: yes
---

# Round 372 — seven ways to end a bidi call

## Target

The owner set a new goal mid-session: take the bidirectional shape seriously —
bugs, leaks, correct handling. That is three questions, and this round takes the
LEAK one, because it is the one where bidi differs structurally from the other
shapes: two independent directions means the most ways to end, and a leak shows
up per ENDING rather than per call.

RPC-05, whose subject is where a resource is charged and released across a
lifecycle. Partial application, scoped to bidi's endings, so the lens does not
get `swept here`.

Correct handling — whether the two directions really are independent — is a
different question with a different bench and is explicitly left to the next
round rather than folded in here (L-12).

## Hypothesis

At least one way of ending a bidi call leaves state behind: a stream entry, a
responder, a live handler, or flow-control bookkeeping.

## Before

Eleven counters, seven endings, three scales, one connection throughout (L-08).
Read after each call settled:

```
ending             5 calls  20 calls  60 calls
unary (control)       0         0         0
normal                0         0         0
consumerCancel        0         0         0
tokenCancel           0         0         0
handlerThrows         0         0         0
deadline              0         0         0
neverFinish           0         0         0
```

Counters: `openStreams`, `activeResponders`, live handlers, transport
`activeStreams` / `streamControllers` / `statusSeen`, and flow control's
`sendCredit` / `deferred` / `owedConn` **on both sides**.

Probe: `packages/core/rpc_dart/.dart_tool/probe/bidi_leak_matrix.dart` (P-63).

**Every cell is zero, so the round rests entirely on the ablation.** Removing the
bidi responder's cleanup — `_detached(responder.done.whenComplete(() =>
_cleanupStream(streamId)))`, both branches, replaced with `Future<void>.value()`
— makes the same counters climb linearly:

```
                 openStreams  responders  fcSrv.sendCredit
after  5 calls        5           5             5
after 20 calls       25          25            25
after 60 calls       85          85            85
```

Restored, `git diff --stat` empty, re-measured back to zero.

## Mechanism

n/a — nothing is broken.

What the numbers say: the cleanup is reached on every ending, including the two
that have no cooperating peer. `neverFinish` is the one worth naming — a caller
that never half-closes and walks away from its subscription leaves nothing,
which is the shape that for other paths has historically parked a responder for
good.

Three scales rather than one because a single reading cannot separate retention
from churn (measurement.md item 7). The curve is flat at zero, not falling.

## After

n/a — no change made.

## Canary

n/a — no fix. The ablation above IS this round's variation, and it is the whole
evidence: a zero is suspicious (measurement.md item 8), so the instrument had to
be shown reporting something else on the same counters at the same scales. It
did, linearly.

## Gate

`melos run analyze` clean; `fvm dart test -j 8` in the package **+1535 ~1**. No
code changed — `git diff --stat` empty before the verdict — so the full
workspace gate from round 371, which passed all four, still stands.

## Not fixed

n/a — nothing found. Three things this round does NOT cover, stated so the
negative is not read wider than it is:

- **RSS, and anything no counter names.** A retained closure that no map keys
  would not show up here.
- **Endings made of latency.** `RpcChannelTransport.pair()` flattens those
  (P-58's lesson), so a teardown race that needs a round trip is untested.
- **Duplex semantics.** Whether the two directions are genuinely independent —
  server push before the client sends, either side finishing first, ordering
  under concurrent traffic — is the next round.

## Links

- RPC-05 — the lens; `applied:` gains 372, status unchanged (partial application)
- P-63 — the bench; its evidence is the ablation, not the zeros
- C-41 — the negative
- L-04 — a guard against an absence is witnessed by an ablation, which is why
  this round has one
- L-08 — one connection for the whole run
- Round 371 — named `_pumpBidirectionalResponses` as a third implementation,
  still unmeasured
