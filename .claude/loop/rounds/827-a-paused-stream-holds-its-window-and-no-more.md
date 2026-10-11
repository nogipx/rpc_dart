---
round: 827
verdict: CLEAN
packages: [rpc_dart, rpc_dart_websocket]
lens: RPC-17
bench: none — one probe, below; it re-measures C-07
commit: yes
release: none
---

# Round 827 — a paused stream holds its window and no more

## Target

`loop.py stale --all`: negative C-07 (outbound backpressure on websocket,
never re-measured since 5bf4d34e) has 92 changes along its paths, the flow
controller among them (rounds 768, 769, 802). Network-audit KV-WS-07 asks
the same question with a second stream on the connection.

## Hypothesis

A paused consumer no longer bounds its producer at the stream window, or
its held credit stalls the other streams on the same connection.

## Before

```
r827_paused_stream.dart 0 (control, A never pauses), 2 s:
  server produced A 1474 (92 MiB), B 1442; B received 1408
```

## Mechanism

n/a (CLEAN).

## After

```
r827_paused_stream.dart 1 (A pauses after its first message), 2 s:
  server produced A 66 (4 MiB, the default stream window), B 2818; B received 2770
```

## Canary

The control is the pause's absence: A's producer runs to 92 MiB without it,
so the stop at 4 MiB is the window.

## The verdict questions

1. Only A's pause differs.
2. Yes: 92 MiB against 4 MiB.
3. At the server: the handler's own count of messages it produced.
4. 2 s; the producer runs at about 46 MiB/s unpaused, so a missing bound
   would show.
5. n/a (CLEAN).
6. n/a.
7. CLEAN with a control.
8. none.
9. none.
10. No code changed.
A1. Default policies, both sides. A2. Volume. L1. n/a.

## Gate

No code changed; the probe is outside the tree.

## Siblings

No code changed. isolate and the channel pair share the flow controller;
C-07's original numbers covered the core pair.

## Not fixed

- The connection window (64 MiB) is shared: sixteen paused streams at the
  4 MiB default hold all of it and stall the rest of that connection. The
  policy doc names this coupling as the price of bounding the total, and it
  is the receiver's own consumers that pause.

## Links

Lens `../lenses/RPC-17-limit-fires-after-residency.md`. Negative
`../checked/C-07-outbound-backpressure-websocket.md` (re-measured).
