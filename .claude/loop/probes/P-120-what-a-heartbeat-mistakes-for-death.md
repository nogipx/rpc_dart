---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/what_a_heartbeat_mistakes_for_death.dart
round: 479
commit: 5592f268
paths: [packages/transport/rpc_dart_websocket/lib/src/websocket_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
status: valid
---

# P-120 — what does a heartbeat mistake for a dead peer?

## Why it exists

B-71's owner decision left one item open and called it part of the round: *"a
heartbeat firing while a long call is in flight competes with it for the
connection window. Measure that before choosing the default interval."*

P-116 measured the COST half (throughput with and without pings). This is the
other half, and **reading the code first moved the question**. The ping sends
only `sendMetadata`, and `sendMetadata` never consults flow-control credit —
only `sendMessage` does. So the connection window is not where a heartbeat and a
long call meet.

`createStream()` is. It throws `resourceExhausted` at
`RpcSecurityPolicy.maxActiveStreams`, and a heartbeat whose catch-all reads every
throw as death closes a healthy connection.

## The harness

Every arm runs against a LIVE rpc_dart responder, so **every close it reports is
a false positive by construction**. Interval 200 ms, read at 3.5 intervals —
long enough for a probe to fire, give up and close.

```
B   at the ceiling      hold all `maxActiveStreams` ids, never release
B*  CONTROL             hold one fewer, everything else identical
C   under a long call   a 120000 x 1 KiB server-stream in flight throughout
```

## The numbers (round 479)

```
arm                                       before fix              after fix
B  at the ceiling (4 of 4 held)           CLOSED (false pos.)     open
B* CONTROL: one id free (3 of 4)          open                    open
C  under a 120000 x 1 KiB stream          open (4720ms)           open (5561ms)
```

## Measures

`transport.isClosed` after a fixed wait, against a peer known to be answering.
Not a duration: the question is a verdict the transport reached, and the only
correct verdict on all three arms is "open".

Arm C additionally reports messages and elapsed, which is what makes a stream
that DIED mid-flight distinguishable from one that completed.

## Control

**B\* is the load-bearing one.** It is arm B with a single id free — same peer,
same interval, same wait, same code path — and it reads `open` while B reads
`CLOSED`. Without it, B is equally consistent with the harness closing the
transport for any other reason.

The `before fix` column is the second control: it is the ablation, and it is not
hypothetical — it is what this round's fix looked like when first written.

## What it establishes, and what it does not

Establishes: the competition the owner asked about is real but not on the axis
named. The WINDOW is clean (arm C), and the STREAM CEILING was fatal (arm B).

Does not establish anything about a peer that answers with an error rather than
silence — `unimplemented` from a responder with no ping handler. That path is
now a skip rather than a close, but no arm here drives it; every peer in the
harness answers ping normally.
