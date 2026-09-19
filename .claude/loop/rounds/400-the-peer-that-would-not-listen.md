---
round: 400
verdict: CLEAN
packages: [rpc_dart_http2]
lens: RPC-22
bench: P-86 — new
commit: yes
---

# Round 400 — the peer that would not listen

## Target

The last item on C-46's uncovered list, and the one that puts a question to
round 397's own fix. That round released the refused stream in a `finally`
placed AFTER `await sendMetadata(...)`. A send that parks on a peer which never
reads would skip the finally and put the state straight back where 397 found it
— 200 streams, their subscriptions, parsers and pumps, held for the life of the
connection.

RPC-22 selected it; the mechanism it turned out to involve is RPC-18's, and the
reassurance it gives is RPC-15's.

## Hypothesis

`await sendMetadata` parks against TCP backpressure, so `releaseStreamId` never
runs and round 397's fix is conditional on the peer's cooperation.

## Before

P-86, new. Round 396's note is what made it planable: the refusal is a
trailers-only HEADERS frame and HTTP/2 flow control covers DATA only, so a zero
receive window will not park it — this needs the peer not reading its socket at
all. Produced with a relay whose server-to-peer subscription is `pause()`d; a
peer that simply never calls `listen` is not enough, because dart:io drains into
its own buffer and the pressure never reaches the far end.

```
arm                opened  delivered     t+4s                t+16s
reads                 400    86640 B     0 / 0 / 0 / 0       0 / 0 / 0 / 0
never reads           400      240 B     0 / 0 / 0 / 0       0 / 0 / 0 / 0
never reads x50     20000      240 B     394 / 394 / 0 / 0   394 / 394 / 0 / 0
```

(incoming / subs / parsers / pumps. 240 B against 86640 is what proves the deaf
arm is deaf.)

Refuted. The fix is not conditional: 400 refusals against a peer that takes none
of them still release everything, and 20000 leave a **plateau of 394** — read
twice, twelve seconds apart, identical.

## Mechanism

`pumps` reads 0 on every arm, which is the direct evidence rather than an
inference: `sendMetadata`'s last act is `_pumpFor(...).add(...)`, so a send
parked in the pump would show there. It never parks, because `package:http2`
queues a HEADERS frame rather than blocking on the socket. Round 396's note was
right and reaches further than it claimed — not only is the window irrelevant,
the socket is too.

So the unread answers accumulate in the DEPENDENCY's outgoing queue, which has
no observable here, and what bounds them is the dependency's own read
backpressure: once it cannot write it stops admitting, which is why only 394 of
20000 attempts became streams at all. The 394 is backlog — streams admitted
whose DATA is not yet processed — not retention, and it sits far below the 4096
an honest peer is already allowed.

## After

n/a — nothing changed, and nothing needed to.

## Canary

n/a — no fix. The load-bearing variation is the **second reading**: one sample
cannot separate a plateau from a slow climb, and that distinction is the entire
verdict.

## What the RSS column is doing there, and why it decides nothing

`-21.8`, `-142.2`, `+107.6` MiB across the three arms. The process holds the
server and the deaf peer with its 20000 streams, so none of it is attributable,
and two of three are negative. Printed so a reader can see memory moved at all;
the verdict rests on the counters. C-29 said this in round 137 — *expose the
counter before trusting the memory* — and round 394 said it again about frames
against RSS. Third time, so it goes in the probe record rather than being
rediscovered.

## Gate

Not run: no library code changed. The only new file is a probe, outside analysis
and the suite by design.

## Not fixed

Nothing found. C-46's uncovered list is now empty except the two refusal
TRIGGERS never driven — `validateMetadata` and content-type — both of which
reach `_answerRejectedStream`, the site round 395 already measured.

## Links

- C-46 — its last uncovered item, answered
- P-86 — new
- Round 397 — its fix re-measured under the condition it was never driven with
- Round 396 — whose note about DATA-only flow control is what made this planable
