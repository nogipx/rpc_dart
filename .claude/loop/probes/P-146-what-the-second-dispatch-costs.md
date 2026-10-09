---
file: packages/core/rpc_dart/.dart_tool/probe/b117_unlistened_buffer.dart
round: 508
commit: 5fa2b280
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart]
status: valid
---

# P-146 — what does the second dispatch cost?

## Why it exists

The lead makes two claims and they need different instruments. One is about speed
("one or two extra broadcast dispatches per response message"); the other is about
structure ("the design makes a missing no-op listener a memory leak"). A throughput
bench answers only the first, and the first turns out to be the smaller of the two.

Two files, therefore:

- `b117_broadcast_per_message.dart` — messages/s for a server stream of small
  messages, which is the witness the lead asks for.
- `b117_unlistened_buffer.dart` — what a caller RETAINS when nobody drains the
  broadcast.

## The harness

**Speed.** A server stream of tiny messages, three counts. Small is the point: the
broadcast is a per-message cost, so it is only visible where per-message cost
dominates, and a large payload would bury it.

**Retention.** The same stream, with `closeCallerResources()` called first to detach
the no-op observer — the shape of an embedder that builds a caller on a transport by
hand. After the stream is FULLY consumed, a late subscriber attaches and counts what
arrives. A `BufferedBroadcastController` replays to a late listener, so what it
retained becomes visible through the public API with no access to private state.

## The numbers (round 508)

Retention, after every message has already been delivered and consumed:

```
                            before   after
  10 messages consumed        11       0
 100 messages consumed       101       0
1000 messages consumed      1001       0
```

The extra one is the trailer. Speed, 10 000 small messages, five runs each:

```
                      min     median    max
always broadcast     5.805    5.987    6.154  us/message
skip when routed     5.481    5.604    5.875  us/message
```

## Measures

Retention: messages replayed to a late subscriber. Exact, integer, and not a timing.

Speed: microseconds per message, **reported as a five-run distribution rather than a
single figure**. The first comparison of this change read 7.072 against 5.966 — a
16% win — while a second arm in the same run moved the wrong way. Printing the
spread showed the real effect is about 6% with the two ranges barely separated. A
single timed comparison of two builds would have overstated it by 2.5x.

## Control

Per-message cost is NOT flat across the three counts (75.8, 17.9, 7.07 us) and that
is itself the control on the speed arm: it says per-CALL setup dominates below a few
thousand messages, so only the largest arm measures a per-message cost at all. A
round quoting the 100-message figure would be quoting call setup.

For retention, `delivered $got` is printed beside the retained count. The zero only
means something if the messages actually arrived — a stream that delivered nothing
would also retain nothing.

## What it establishes, and what it does not

Establishes: every inbound message was dispatched twice, and for a caller the second
dispatch was pure retention — 1001 messages held for a stream whose 1000 messages
had all been consumed. Skipping it for locally-initiated routed streams takes that
to 0 and is worth about 6% of per-message time.

**Does NOT support the lead's framing of the cost.** "One or two extra dispatches per
message" sounds like the dominant term and it is not; at 6% it is a rounding error
next to the ~6 us per message the path costs. The retention is the finding.

Nor does it cover the websocket transport's second broadcast, which the lead also
names (`websocket_caller_transport.dart` re-broadcasting with a set lookup per
message). Only the core channel transport was varied.

## Reading

rpc_dart — **two files because the lead makes two claims needing different
instruments**, and the one it leads with turned out to be the smaller.
Retention is read through the PUBLIC API with no access to private state: a
`BufferedBroadcastController` replays to a late subscriber, so attaching one
after the stream is fully consumed counts exactly what was held for nobody.
The speed arm reports a five-run distribution rather than a figure — a single
comparison read 16% where the real effect is 6% — and its control is that
per-message cost is NOT flat across counts, which says only the largest arm
measures a per-message cost at all.
