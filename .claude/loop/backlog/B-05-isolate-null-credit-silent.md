---
status: open
round: — (not re-measured)
commit: 5bf4d34e
paths: [packages/transport/rpc_dart_isolate/lib/**]
probe: —
reason: zero credit is deliberately read as "the peer does not participate" — the degradation path for an older peer
---

# B-05 — isolate: a window-credit failure is silent

Zero credit is read as "the peer does not participate", which is the deliberate
degradation path for an older peer. So a lost grant is indistinguishable from an
old peer, and the failure is silent.

Measured: connection window 8 KiB, per-stream window off, an inert worker →
200/200 chunks went out before the fix, 8/200 after.

A related trap: `BufferedBroadcastController` does NOT close the window before
readiness — its flush runs synchronously from inside `listen()`, i.e. from the
channel's constructor, into a controller the transport has not subscribed to
yet; the frames are lost one hop later. Subscribing early closes the window on
both hops.

## Owner decision

—
