---
status: closed (round 533)
round: 533
commit: 53cc91a7
paths: [packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart]
probe: P-166
reason: "CONFIRMED at one descriptor per abandoned attempt and FIXED by giving a bounded open its OWN HttpClient — which the ablation shows is the part that matters, not either of the settings on it"
---

# B-137 — websocket connect timeout abandons the wait, not the TCP attempt

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`Future.timeout` stops waiting while the TCP connect continues until the OS gives up, holding a descriptor for minutes against a black-holed address.

## The shape

`packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart:78-96`.

## Why it matters

Descriptor build-up under a reconnect loop against an unreachable host.

## What round 533 measured

```
  baseline TCP fds                      0

  arm                                   settled as        TCP fds after
  CONTROL 40 opens that SUCCEED and close   40 opened         1
  40 opens to a BLACK HOLE             40 timed out      40
```

Bench `../probes/P-166-does-a-timed-out-connect-hold-its-descriptor.md`. After: `0`.

Counted with `lsof` from outside Dart — the process keeps working, the socket is invisible to
Dart, and the attempt reports failure on time. The arm asserts its own premise (all forty settled
as `TimeoutException`), and a missing `lsof` exits 2.

## Fix

The sketch works, and the ablation says why — but not for the reason the sketch gives.
**Reverting the forced close to a plain one leaves the witness passing. Removing
`connectionTimeout` leaves it passing. Passing the SHARED client fails it at 20 of 20.** So what
matters is OWNING the client; the settings on it are belt-and-braces, and neither can be separated
from the other because both bounds are the same duration.

The client is closed on both exits: forced on failure, plain on success — where the upgraded
socket has already been detached from it. Two guards bound that: a successful connect still answers
an RPC after its client is closed, and an unbounded open (no private client) is unchanged.

## Owner decision

—
