---
round: 600
verdict: CLEAN
packages: [rpc_dart]
lens: RPC-15
bench: P-214 — new
budget: probes 0/5, canaries 0/5
commit: yes
release: none
---

# Round 600 — the queue was the bench

## Target

B-217, in the rpc_dart scope and in the family rounds 594-595 just worked: "the
connection-wide `_incoming` buffer holds direct objects without limit — measured at
355 MiB". Reading `BufferedBroadcastController` first changed the question: it
buffers ONLY while nobody listens, and it has a count bound (`maxPendingEvents`,
4096). The 355 MiB arm subscribed to `incomingMessages` and PAUSED it — and a paused
broadcast subscription buffers inside dart:async, not in the library.

## Hypothesis

The 355 MiB was the probe's own paused subscription. With the subscription
consuming, as every endpoint does, nothing accumulates. Refuted if the draining arm
also grows.

## Before

```
arm        retained (400 minted 1 MiB direct objects)   delivered
paused     +392 MiB                                        0
draining     +6 MiB                                      401
none       +376 MiB                                        0
```

No per-stream consumer in any arm, one arm per process. Probe:
`packages/core/rpc_dart/.dart_tool/probe/b217_who_holds_the_connection_queue.dart`.

## Mechanism

`BufferedBroadcastController.add` hands an event straight to the broadcast
controller when anyone listens; a paused broadcast subscription then queues it in
dart:async. Only with NO listener does the library's own queue hold anything, and
then the byte bound cannot see a direct payload (it weighs 0), so the 4096-event
count is the only limit.

## After

n/a — no change.

## Canary

n/a — no fix. The `paused` and `draining` arms differ by exactly the pause, which
is the control.

## Gate

Not run: `lib/` and `test/` byte-identical to the previous commit.

## Not fixed

The `none` arm is real: a transport nobody consumes, fed zero-copy, holds up to 4096
direct objects of any size. It needs both an abandoned transport and an in-process
peer (`memoryPair`), and it is the same gap as B-225 item 2 (zero-copy weighs
nothing), so it is recorded there rather than as its own lead.

## Links

Lead `../backlog/B-217-the-connection-wide-buffer-has-no-depth.md` — closed.
Lead `../backlog/B-225-what-the-connection-total-does-not-see.md` — item 2 extended.
Negative `../checked/C-63-a-consumed-connection-queue-holds-nothing.md` — new.
Bench `../probes/P-214-who-holds-the-connection-queue.md` — new.
Lens `../lenses/RPC-15-remeasure-own-record.md` — `applied: [600]`.
