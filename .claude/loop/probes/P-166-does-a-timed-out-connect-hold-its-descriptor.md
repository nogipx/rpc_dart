---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b137_connect_timeout_fds.dart
round: 533
commit: 53cc91a7
paths: [packages/transport/rpc_dart_websocket/lib/src/ws_open_io.dart]
status: valid
---

# P-166 — does a connect that timed out still hold its descriptor?

## Why it exists

The leaked thing is a file descriptor, and every indirect reading of one sits behind a retry
schedule the OS controls: the process still works, the socket is invisible to Dart, and the
attempt reports failure on time. So the count is taken from outside Dart — `lsof` against this
process — and nothing else in the run is evidence.

## The harness

Forty opens to `ws://192.0.2.1:9/` with a 100 ms `connectTimeout`. That address is RFC 5737
TEST-NET-1, guaranteed not routed, so the SYN goes out and nothing ever answers.

**The arm asserts its own premise**: every attempt must settle as `TimeoutException`. On a machine
where the address answers, or fails fast with "no route", the count would be zero for a reason
that has nothing to do with the defect — so a run where any attempt settled differently prints a
warning naming how many.

**A missing `lsof` exits 2.** A count that measured nothing must not read as a pass.

## The numbers (round 533)

```
  baseline TCP fds                      0

  arm                                   settled as        TCP fds after
  CONTROL 40 opens that SUCCEED and close   40 opened         1
  40 opens to a BLACK HOLE             40 timed out      0
```

Before the fix the black-hole row read **40** — one descriptor per abandoned attempt. The
control's `1` is the local server's own listening socket, still bound when the count is taken.

## Measures

TCP descriptors held by this process two seconds after every attempt has reported failure — well
short of any OS connect timeout, and long enough that anything settling by itself has settled.

## Control

**Forty opens that succeed and are closed.** Without it, a low count after the fix is equally
consistent with the rig never opening anything, and `lsof` parsing is exactly the kind of thing
that silently returns zero.

## What it establishes, and what it does not

Establishes: a `Future.timeout` over `WebSocket.connect` leaves one descriptor per abandoned
attempt, held until the OS gives up.

Does NOT distinguish the two halves of the fix. Giving the attempt a private `HttpClient` is what
the ablation shows to matter — reverting to the shared client restores 20 of 20 — but the
client's `connectionTimeout` and the forced close on the catch path could not be separated from
each other, because both bounds are the same duration. Removing either one alone left the count
at zero.

Does NOT hold on any platform. `lsof` is not portable, and the address being a black hole is a
property of the network the run is on — which is why both are asserted rather than assumed.
