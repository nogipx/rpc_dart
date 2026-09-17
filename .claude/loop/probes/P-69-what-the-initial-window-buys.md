---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/initial_window_what_it_buys.dart
round: 380
commit: 4bc160ca
paths: [packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/rpc/transports/flow_controller.dart, packages/transport/rpc_dart_websocket/lib/**]
status: valid
---

# P-69 — what the initial send window buys

## Why it exists

B-47 said `initialSendWindowBytes` buys nothing. The field's own doc comment said
otherwise with numbers. `measurement.md` forbids trusting either — a measured
table inside a comment is a record of somebody's run — so this measures it.

## Measures

How many frames a caller gets out **before the first grant can throttle it**,
counted inside the caller's own producer. Reported as frames and MiB.

Rig: a real websocket server, the client through toxiproxy with a 25 ms latency
toxic on each stream (50 ms RTT), a handler that never reads so no credit is
ever returned, 4 KiB frames, 40000 offered, sampled at 3 s.

**The RTT is not optional.** Credit exists only once a grant has arrived, so the
window covers a latency gap; on an in-process pair the grant is already there
and the field looks inert. That is exactly how round 366 came to call it
useless.

## Control

Four policies on one rig in one run, differing only in the window:

```
policy                            frames      MiB
no initial window (5.0.1 shape)    40000   156.25
64 KiB (shipped default)            1039     4.06
= maxMessageSize (16 MiB)           5108    19.95
= maxMessageSize / 16 (1 MiB)       1278     4.99
```

The `null` row is the control that matters: it runs the producer to exhaustion,
so the bench demonstrably reaches the regime the field is for, and every other
row is a real bound rather than a slow producer.

The first two rows reproduce the doc comment to within 0.01 MiB, which is a
second, independent control — the same numbers from a different session on a
different harness.

## What it establishes, and what it does not

Establishes: the window bounds a burst by a factor of 38, and deriving it from
`maxMessageSize` would weaken that fivefold.

Does not establish anything about a SINGLE message larger than the window: that
one passes regardless, because the gate admits on `credit > 0` rather than on
fit. Both facts are true, and conflating them is what round 366 did.
