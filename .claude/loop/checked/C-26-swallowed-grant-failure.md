---
round: 230
commit: 9b7f3914
paths: [packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart, packages/core/rpc_dart/lib/src/core/channel_frame.dart]
scope: [core]
---

# C-26 — the swallowed grant failure is unreachable, and load-bearing

`_fcSendGrant` swallows everything:

```dart
} catch (_) {
  // A lost grant only matters if the connection is still alive, and a throw
  // here means it is not; the normal paths report that.
}
```

U-01: a comment justifying deliberateness is a lead. Round 230 took it.

## The premise holds, by construction

A grant is a metadata frame carrying one header whose name and value are both
`String`. Following what can throw on the way out:

```
  RpcChannelFrame.encodeMetadata      -> _encodeMetadataPayload:
                                         json.encode over Strings, utf8.encode.
                                         No throw path. Every RpcFrameException
                                         in that file is in _decodeMetadataPayload
  RpcFrameMultiplexedChannel.send     -> `if (_closed) return;` — a closed
                                         channel is a silent no-op, NOT a throw
  the byte channel                    -> websocket `_ws.sink.add` throws only
                                         after the sink is closed; isolate
                                         SendPort.send throws on an unsendable
                                         object, and a Uint8List always is
```

So today the only way to reach that `catch` is a byte channel that is already
failing — which is what the comment claims.

## What it costs if the premise ever stops holding

Measured by planting a throw at the top of `_fcSendGrant`, on an in-memory pair
where the connection is provably alive (P-11's rig, `initialSendWindowBytes`
64 KiB):

```
                                 normal        every grant throws
  receiver drains              3072 KiB          64 KiB, wedged at call 0
  receiver never reads         3072 KiB          64 KiB, wedged at call 0
  receiver binds and pauses    1024 KiB          64 KiB, wedged at call 0
  per-stream window OFF        3072 KiB        3072 KiB, never wedged
```

64 KiB is the seed exactly. The sender spends what it had before the peer spoke
and then **wedges for good, in silence** — the connection is healthy, nothing is
logged, and no path reports anything.

## Control

Two, and they point in opposite directions.

**The fourth row is the mechanism control.** With the per-stream window OFF
there are no per-stream grants to lose, and that arm does not move under the
plant — 3072 KiB either way. So the wedge in the other three is the lost grants
and not the plant's mere presence.

**The unablated run is the drift control.** It reproduced round 228's numbers
exactly — 3072 / 3072 / 3072 with CASE C wedging at call 4 — so the bench had
not aged between the rounds.

## Why this is a negative and not a finding

The `catch` is correct for every channel in the repository, and the ablation
needed an artificial throw to reach it. But the comment states a conclusion
("a throw means the connection is dead") that is a property of the CHANNELS,
not of this function — nothing enforces it, and a future channel that throws
non-fatally on send would wedge the connection permanently with no trace.

Not fixed, deliberately: the only remedy is a log, and the config's severity bar
rules diagnostics out as a round's product. Recorded so the trade is visible.

Sibling: `../backlog/B-05-isolate-null-credit-silent.md`, whose logging half is
the same argument from the receiving end.
