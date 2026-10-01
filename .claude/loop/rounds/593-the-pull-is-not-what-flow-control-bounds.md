---
round: 593
verdict: INCONCLUSIVE
packages: [rpc_dart]
lens: RPC-17
bench: P-210 — new
budget: probes 3/5, canaries 0/5
commit: yes
release: none
---

# Round 593 — the pull is not what flow control bounds

## Target

`B-138`'s remaining subject, the one round 534 left: with rpc_dart's flow control
OFF — which is what a foreign or legacy peer amounts to — what bounds an inbound
flood?

## Hypothesis

The lead names `_admitToStreamBuffer` and `maxMessageLengthBytes` as the bounds and
says neither was measured.

## Before

```
                                      PULLED   delivered   errors   resident
CONTROL  flow control ON, 64 KiB      20001        0          0      +34 MiB
WITNESS  flow control OFF             20001        0          0      +40 MiB
```

320 MiB offered as 20000 frames of 16 KiB on one peer-minted stream, consumer
paused. Probe:
`packages/core/rpc_dart/.dart_tool/probe/b138_what_bounds_a_flood_without_flow_control.dart`.

## Mechanism

rpc_dart's flow control is a SEND-side credit protocol. It bounds what this side
sends and it asks the peer to stop by withholding grants — so it is not on the path
the inbound bytes arrive by, and a peer that does not implement it is outside it by
construction. Nothing in the window's design throttles READING, which is why both
arms pull identically.

What the lead names as the inbound bounds — `_admitToStreamBuffer` and
`maxMessageLengthBytes` — sit ABOVE the transport, so they are reached only once a
message is dispatched to a stream. Whether this rig dispatches anything is exactly
what it fails to establish.

## After

No change. The round is a measurement and it came back short of its question.

## What is established

**The transport reads every frame, and flow control does not change that.** Both
arms pull all 20001. That is not a defect by itself and it is worth writing down:
rpc_dart's flow control is a SEND-side credit protocol. It bounds what this side
sends and it asks the peer to stop by withholding grants — so against a peer that
ignores grants it does nothing, and it never throttles READING. The lead's framing
("only rpc_dart's own flow control bounds a peer") is therefore right about the
limit and wrong about which direction it works in.

**The bytes are not retained here**: `+34` and `+40 MiB` against 320 MiB offered.

## Why this is INCONCLUSIVE and not a finding

Residency that low with nothing refused means the frames are DISCARDED rather than
buffered, and the most likely reason is the rig: a peer-minted stream with no
responder endpoint attached has nowhere to be dispatched. So the arm may be
measuring an absent consumer rather than a present bound, and
`_admitToStreamBuffer` — the thing the lead names — is still not shown to have been
reached.

## Three rig failures, recorded because each one read as a result

1. **A `StreamController` source measures the BENCH.** Pushing 20000 frames into a
   controller the transport listens to read `+316 MiB` with flow control ON and
   `+300` with it OFF — the controller queueing 320 MiB, and a window has nothing
   to act on because there is no peer waiting for credit. `measurement.md` item 6.
2. **A data frame for a stream nothing opened is silently dropped.** The first
   version fed only data frames and read `delivered 0, errors 0` on every arm,
   which is the transport ignoring frames for streams that do not exist, not a
   bound. Fixed by sending the opening metadata frame per stream.
3. **`health().details` has no buffer depth.** `activeStreams` counts streams THIS
   side opened (0 here) and `streamControllers` counts `getMessagesForStream` calls,
   so it counts the probe's own subscriptions. Neither is the thing to read.

The instrument that works is the one `P-167` already established for this lead's
first half: an `async*` generator that counts its own yields, so the number is the
transport's DEMAND rather than the bench's capacity.

## What the next round needs, precisely

Attach an `RpcResponderEndpoint` to the transport with a handler that never
returns, so a peer-minted stream is dispatched and its messages are buffered where
`_admitToStreamBuffer` can refuse them. Then read `PULLED`, the first error, and
residency across: flow control off, `maxBufferedMessagesPerStream` at its default
and lifted, and N streams against `maxActiveStreams` — because the per-stream bound
times the stream ceiling is the total a peer can command, and that product is the
number the lead is really asking for.

## Canary

None — nothing was fixed.

## Gate

Not run: `lib/` and `test/` are byte-identical to the previous commit.

## Not fixed

The lead stays OPEN with its remaining subject narrowed and the three dead ends
closed off, which is what this round is worth.

`IRpcChannel`'s own example and the isolate and wasm channels are still unswept —
RPC-08's shape, named by round 534 and untouched here.

## Links

Lead `../backlog/B-138-the-websocket-channel-has-no-read-backpressure.md` — still open.
Bench `../probes/P-210-what-the-transport-pulls-from-a-flooding-peer.md` — new.
Bench `../probes/P-167-does-pause-reach-the-socket.md` — the instrument this round
had to rediscover.
Lens `../lenses/RPC-17-limit-fires-after-residency.md` — `applied: [593]`.
