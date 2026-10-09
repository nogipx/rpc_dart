---
round: 766
verdict: FIXED
packages: [rpc_notify]
lens: RPC-18
bench: P-266 — new
commit: yes
release: changelog
---

# Round 766 — a subscriber that stops reading held the topic

## Target

`rpc_notify`'s server, raised in round 765's triage. Every repository hands
out a broadcast `StreamController` per subscriber (`StreamDistributor` in
memory, `RedisNotifyRepository`, `PostgresNotifyRepository`), and a paused
subscription to a broadcast stream buffers in dart:async with no limit. The
README promises fire-and-forget with no backlog. The class: three
repositories, one remote entry point (`NotifySubscribeResponder.subscribe`).

## Hypothesis

A remote subscriber that stops reading stops granting credit, the response
stream pauses its source, and the server holds every event published to the
topic for as long as that subscriber stays connected.

## Before

P-266, two processes, 3000 events of 64 KiB:

```
  paused   responder took 66 of 3000   SERVER rss +195 MiB
  reading  responder took 3000         SERVER rss -65 MiB
```

One process: 1000 -> +89 MiB, 4000 -> +267 MiB, against +30 / +31 reading.

## Mechanism

Flow control did its part: the responder stopped after 66 events. The rest
waited in the broadcast subscription's pending queue, below every limit
rpc_dart has. Fix at the one remote entry point, so it covers every
repository: `NotifySubscribeResponder` wraps the stream in
`boundWhilePaused`, which never pauses the source, holds at most
`maxPendingEvents` (1024) and `maxPendingBytes` (8 MiB, estimated from topic
and payload) while its listener is paused, drops past either, counts
`droppedEvents` and warns once.

## After

```
  paused   source delivered 3000   dropped 2806   SERVER rss +20 / +35 / +47 MiB
  reading  source delivered 3000   dropped 0
```

2806 = 3000 - 128 held (8 MiB) - 66 in flight.

## Canary

`packages/notify/rpc_notify/test/a_subscriber_that_stops_reading_is_bounded_test.dart`,
4 tests, 3 of 3 runs green.

```
  bound bypassed     Expected: a value greater than <200>  Actual: <0>
                     the server kept what a paused subscriber did not read
  drain on resume    Expected: [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]  Actual: []
  off                (the stall test: Actual: [0, 1] of 50)
```

## The verdict questions

1. The arms differ in whether the child pauses its subscription.
2. Yes: 66 against 3000 taken; dropped 2806 against 0.
3. In the server process: the count between repository and responder, and
   its own RSS; the subscriber is another process.
4. n/a.
5. Yes, both messages above.
6. Two halves (bound, drain on resume), two canaries.
7. FIXED from the counts.
8. Redis and Postgres repositories were not run (infra); they are covered
   because the bound sits in the responder, above any repository. In-process
   subscribers (`INotifySubscriber.repository`) are not bounded: a paused
   local listener is the application's own buffer.
9. None.
A1. Separate processes, separate endpoints; both default policy.
A2. Volume.
L1. The bound under test is `maxPendingBytes` (128 x 64 KiB); the event
    count (1024) is never reached.

## Gate

`melos run analyze`, `format:check`, `test:unit` green; rpc_notify 69 + 4.

## Not fixed

`NotifySubscriber` on the client side forwards into its own broadcast
controller, so a paused local listener there buffers in the client's memory:
the client's own choice, not reachable by a peer.

## Links

Probe `../probes/P-266-what-the-notify-server-holds-for-a-paused-subscriber.md`.
Lens `../lenses/RPC-18-dependency-buffers-below-your-limits.md`.
Lens `../lenses/RPC-27-a-bound-counted-in-the-wrong-unit.md` (the triage that
found it).
