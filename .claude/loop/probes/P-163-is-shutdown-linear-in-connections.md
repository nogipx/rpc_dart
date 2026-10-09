---
file: packages/transport/rpc_dart_websocket/.dart_tool/probe/b134_serial_stop.dart
round: 530
commit: e4ba8c6b
paths: [packages/transport/rpc_dart_websocket/lib/src/rpc_websocket_server.dart]
status: valid
---

# P-163 — is the websocket server's shutdown linear in its connections?

## Why it exists

The real cost per connection is dart:io's close timeout for a peer that never answers the
close handshake, which is seconds. Driving that needs a raw TCP peer that completes a
WebSocket handshake and then goes silent, and it makes every arm slow.

The property under test is not the timeout, it is the SERIALISATION: serial shutdown costs
N x per-peer, concurrent costs one. So the rig fixes the per-peer cost at a small constant
and varies N.

## The harness

A channel whose `sink.close()` takes a fixed delay, fed to `RpcWebSocketServer` through its
`connections` stream. `stop()` is timed with a `Stopwatch` around one call.

The channel's inbound controller stays OPEN. `Stream.empty()` ends immediately, which tears
the endpoint down before `stop()` ever sees it, and every arm then reads fast for the wrong
reason.

## The numbers (round 530)

```
  arm                                    stop() took
  1 peers, close takes 300ms             316ms
  5 peers, close takes 300ms             1512ms
  20 peers, close takes 300ms            6057ms
  CONTROL 20 peers, close is instant     1ms
```

After the fix: `316ms / 304ms / 304ms`, control unchanged.

## Measures

Wall time of one `stop()`, against the number of connections. Read as a RATIO to the
single-peer arm — an absolute threshold would encode this machine.

## Control

**Twenty peers whose close is instant, at 1 ms.** Without it, the growth is equally
consistent with a per-endpoint bookkeeping cost, and a "fix" that sped up the bookkeeping
would look right.

The witness test adds the other control the probe cannot give: **every sink must record that
its close was CALLED.** Fast is also what abandoning the endpoints looks like.

## What it establishes, and what it does not

Establishes: `stop()` was exactly linear in connections, at the per-peer close cost. With
dart:io's real close timeout the same shape puts twenty dead peers at around a hundred
seconds.

Does NOT measure dart:io's close timeout. The 300 ms is a stand-in chosen to make the
serialisation visible, and no arm involved a real socket.

Does NOT say anything about `drainTimeout`. Every arm passes null, so the drain path is
untouched by this measurement.

## Reading

rpc_dart_websocket — **fixes the per-item cost small and varies N**, because
the property under test is the serialisation and the honest magnitude
(dart:io's close timeout for a peer that never answers) needs a raw TCP peer
and makes every arm slow. Read as a RATIO to the single-peer arm, so the
assertion does not encode the machine. Its control is twenty peers whose close
is INSTANT — without it the growth is equally consistent with a per-endpoint
bookkeeping cost. Its channel's inbound controller must stay OPEN:
`Stream.empty()` tears the endpoint down before `stop()` sees it and every arm
reads fast for the wrong reason.
