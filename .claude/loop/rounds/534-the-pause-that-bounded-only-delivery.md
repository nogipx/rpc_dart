---
round: 534
verdict: FIXED
packages: [rpc_dart_websocket]
lens: RPC-17
bench: P-167 — new
commit: yes
severity: S2
---

# Round 534 — the pause that bounded only delivery

## Target

B-138, next in rank order: the websocket channel does not propagate pause to the socket.

Lens RPC-17 — a limit that fires after residency. A paused consumer IS a limit; here everything
arrived and was held anyway, so the limit applied to delivery and not to residency.

## Hypothesis

`_incoming` has no `onPause`/`onResume` wired to `_sub`, so a paused consumer never slows the
socket.

## Before

```
  arm                          chunks pulled from source   delivered
  consumer PAUSED              5000                        0
  CONTROL not paused           5000                        5000
  GUARD paused then resumed    5000                        5000
```

Bench `../probes/P-167-does-pause-reach-the-socket.md`.

CONFIRMED, and total: with the consumer paused, every chunk was still pulled from the source and
none delivered. **Reframed from memory to demand** — the source is an `async*` generator counting
its own yields, which suspends while its subscription is paused, so the reading is a count rather
than an RSS figure that P-128 showed is noise across arms here. Both columns are read, because the
defect is exactly that they disagree.

## Mechanism

`_incoming` is a `StreamController` with no `onPause`/`onResume`, so pausing its subscriber does
nothing to `_sub`. The layer BELOW already does this correctly: dart:io's `_WebSocketImpl` wires
its own controller's `onPause`/`onResume` to the socket subscription. The chain was complete
except for this link.

## After

The paused arm reads `1` — the chunk already in flight when the pause landed. Controls unchanged.

## Canary

The two lines removed in place: the witness fails `Expected: a value less than <10> / Actual:
<5000>` with its own reason. Both controls pass in that state, which is what says the witness reads
the wiring and not the rig.

## Gate

`analyze`, `format:check`, `test:unit`, `license:check` — all green. The websocket package: 235
passed.

## Not fixed

**Nothing in rpc_dart pauses this stream, so nothing in this library behaved differently before or
after.** Neither `RpcFrameMultiplexedChannel` nor `RpcChannelTransport` ever calls `pause`. What
the gap exposed is a caller holding the channel directly, plus the `IRpcChannel` contract that
`incoming` is an ordinary Stream — so this closes a contract, not an observed failure. The lead was
filed as `cost` and that grading is right.

**The lead's real subject is untouched.** "A legacy peer flooding a paused consumer" needs a
consumer that pauses, and rpc_dart has none: with flow control off, what bounds an inbound flood is
`_admitToStreamBuffer` and `maxMessageLengthBytes` above the transport, which this round did not
measure. Whether those suffice for a peer outside the protocol is the question the lead was
pointing at, and it is still open.

**The siblings were not swept.** `IRpcChannel` is a documented ~50-line extension point and the
example in its own doc has this same gap; the isolate and wasm channels were not checked. RPC-08's
shape, unexamined.

**A long pause is not free, and that is stated in the code rather than measured.** dart:io answers
pings inside the subscription this suspends, so a consumer that stays paused stops answering them
and a peer with a keepalive will eventually call the connection dead.

**The window before the first listener is a separate gap.** `_incoming` has no `onListen`, so
chunks accumulate from construction until something subscribes. `RpcChannelTransport` subscribes in
its own constructor so the window is brief — RPC-20's shape, not examined here.

## Links

Lens RPC-17. Bench P-167 (new). Lead B-138 closed as a contract gap. The unmeasured half — what
bounds a foreign peer's flood — belongs with RPC-17's existing work and `checked/C-29`.
