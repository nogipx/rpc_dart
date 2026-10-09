---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/does_the_ceiling_reach_keepalive.dart
round: 479
commit: 5592f268
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
status: valid
---

# P-121 — does the stream ceiling reach HTTP/2 keepalive?

## Why it exists

The sweep half of round 479. P-120 found that the websocket caller's new
heartbeat read EVERY throw as a dead peer, so at `maxActiveStreams` — where
`createStream()` throws `resourceExhausted` — it closed a healthy connection.

`startHttp2Keepalive` is the SAME loop with the same `catch (error) { …
onDead(error) }`, and this transport enforces the same ceiling in its own
`createStream` (`rpc_http2_caller_transport.dart:727`). Reading says it cannot
bite here, because the probe is `connection.ping` — a protocol-level PING frame
that opens no stream and is charged to no limit.

**That is an argument, and the sweep needs a measurement.** This probe is the
measurement.

## The harness

Arms 1 and 2 mirror P-120's B and B\*: a live `RpcHttp2Server`, all four stream
ids held versus three, keepalive at 200 ms, read at 3.5 intervals. The verdict is
`transport.health()`, which is where this transport reports a dead path
(`onDead` sets `_disconnected` and discards the connection).

Arm 3 is the frozen relay from `caller_keepalive_detects_half_open_test.dart`:
both sockets open, bytes stopped, no FIN and no RST.

## The numbers (round 479)

```
4 of 4 streams held                  ready
3 of 4 streams held                  ready
0 of 4 held, path FROZEN             DOWN (correct: the path IS dead)
```

## Measures

Whether `health().message` contains `down`. On the frozen arm `down` is the RIGHT
answer; everywhere else it is the defect. The probe labels the two differently so
the output cannot be read the wrong way round later.

## Control

**Arm 3 is the whole reason this is a bench and not an observation.** Two arms
reading `ready` are equally consistent with a keepalive that never fired inside
the 700 ms window — a void arm reads exactly like a clean one (L-15). The frozen
arm fires inside that same window, at that same interval, and flips health to
`down`. So `ready` on arms 1 and 2 means the ceiling did not reach the probe,
rather than that nothing was probing.

## What it establishes, and what it does not

Establishes: HTTP/2 keepalive is clean against the defect P-120 found, and clean
for the structural reason — its probe opens no stream, so no stream limit can
refuse it.

Does not establish that `startHttp2Keepalive`'s catch-all is harmless in
general. It is still "any throw means dead"; what this measures is that the one
known non-death throw cannot reach it. A future `ping` implementation that
allocates anything would put the shape back in play.

## Reading

rpc_dart_http2 — **the sweep arm: does the stream ceiling reach HTTP/2
keepalive?** P-120 found the websocket heartbeat closed a healthy connection
at `maxActiveStreams`, and `startHttp2Keepalive` is the same loop with the
same `catch (error) { … onDead(error) }`. Reading says it cannot bite — the
probe is `connection.ping`, a protocol frame charged to no stream limit — and
this is that argument turned into a measurement: `ready` at 4 of 4 held and at
3 of 4. **The third arm is the reason it is a bench**: two `ready`s are
equally consistent with a keepalive that never fired in the 700 ms window, so
a frozen relay (both sockets open, bytes stopped) shows the same loop at the
same interval flipping health to `down`. Clean, and clean for a structural
reason — a future `ping` that allocated anything would put the shape back in
play
