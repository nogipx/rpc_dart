---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/peer_that_never_reads.dart
round: 400
commit: c157760f
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_responder_transport.dart]
status: valid
---

# P-86 — a peer that refuses to read its own refusals

## Why it exists

The last item C-46 listed as uncovered, and the one that questions round 397's
fix: that round put `releaseStreamId` in a `finally` AFTER `await
sendMetadata(...)`. A send that parks on a peer which never reads would skip the
finally and put the state straight back where round 397 found it.

Round 396 left the note that makes it planable: the refusal is a trailers-only
HEADERS frame, and HTTP/2 flow control covers DATA only, so a zero receive
window does NOT park it. This needs TCP-level backpressure.

## Measures

The four per-stream collections from the server's `health()`, read TWICE — at
t+4s and t+16s — plus how many streams the peer got open and how many bytes the
relay let through.

## How "never reads" is produced

A relay between peer and server, whose SERVER->PEER subscription is `pause()`d.
That stops the relay reading the server's socket, the OS buffer fills, and TCP
backpressure reaches the server. The peer->server direction keeps flowing, so
the peer can go on opening streams.

A peer that simply never calls `listen` is NOT enough: dart:io drains into its
own buffer and the pressure never reaches the far end.

## Control

`reads` — the identical run with the relay forwarding. 86640 B delivered
against 240 B, which is what proves the deaf arm is actually deaf.

And the **second reading at t+16s**, which is the control on the verdict rather
than on the setup: one reading cannot tell a plateau from a slow climb, and that
distinction is the whole result.

## The numbers (round 400)

```
arm                opened  delivered     t+4s                      t+16s
reads                 400    86640 B     0 / 0 / 0 / 0             0 / 0 / 0 / 0
never reads           400      240 B     0 / 0 / 0 / 0             0 / 0 / 0 / 0
never reads x50     20000      240 B     394 / 394 / 0 / 0         394 / 394 / 0 / 0
```

(incoming / subs / parsers / pumps.)

## RSS is in the output and must not be read as the server's

`-21.8`, `-142.2`, `+107.6` MiB across the three arms. The process holds the
server AND the deaf peer with its 20000 streams, so nothing here is attributable
to either, and two of the three are negative. It is printed so a reader can see
memory moved at all; the verdict rests entirely on the counters. C-29 said this
before: expose a counter before trusting memory.

## What it establishes, and what it does not

Establishes: a deaf peer cannot make the server's per-stream state grow. 20000
attempts leave 394 streams, unchanged twelve seconds later — a plateau, and far
below the 4096 an honest peer is already allowed. `pumps` reading 0 throughout
is the direct evidence that `sendMetadata` never parked, so round 397's
`finally` always ran.

Does not measure `package:http2`'s outgoing queue, which is where the unread
answers actually sit and which has no observable. What bounds THAT is the
dependency's own read backpressure: once it cannot write, it stops admitting,
which is why only 394 of 20000 became streams at all.
