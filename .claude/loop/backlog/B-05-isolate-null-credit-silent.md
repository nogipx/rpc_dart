---
status: closed (round 229) — the zero-grant half fixed; the logging half is a diagnostic, below the bar
round: 229
commit: e6d5cd79
paths: [packages/transport/rpc_dart_isolate/lib/**]
probe: —
reason: zero credit is deliberately read as "the peer does not participate" — the degradation path for an older peer
---

# B-05 — isolate: a window-credit failure is silent

> **Closed by round 229, and it was bigger than "silent".** A peer whose first
> grant was ZERO was never recorded as participating, so the legacy grace
> expired and the sender went unbounded against a peer that had just said it had
> no room: 800 KiB through a 64 KiB window, 16 KiB after the fix, 20 KiB in the
> control. Both call sites gated participation on `parsed > 0` while
> `_fcNotePeerGranted`'s own doc says "a grant frame at all is the proof; its
> value is not". Bench
> [P-12](../probes/P-12-zero-grant-reads-as-legacy.md).
>
> **The logging half stands and is deliberately not fixed**: assuming a legacy
> peer still writes nothing anywhere. That is a diagnostic, which the config's
> severity bar rules out as a round's product.

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
