---
status: open
round: 240
commit: c84ff1cf
paths: [packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/rpc/transports/channel_transport.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/rpc20_proxy_window.dart
reason: cost — no reachable loss was measured, so a fix would be pre-emptive; taking it now would ship a change with no witness, which the canary rule forbids
---

# B-24 — the frame channel's buffer is an ordering coincidence

`RpcFrameMultiplexedChannel._incomingCtl` is a plain
`StreamController.broadcast()`, and the constructor starts decoding into it
immediately (it subscribes to `_channel.incoming` from its own constructor). It
is the second plain broadcast the round 240 detector found on an inbound path.

**Nothing loses a frame today**, and that is exactly what makes this a lead and
not a finding. Every construction in the library goes through
`RpcChannelTransport.fromChannel`, which builds the frame channel and the
transport in ONE expression:

```dart
return RpcChannelTransport(
  channel: RpcFrameMultiplexedChannel(channel: channel, ...),
  ...
);
```

No await between them, so no byte can land in the gap.

## Why it is worth a record anyway

- **The safety is an ordering property of a constructor, not an invariant.**
  Anything that later separates those two constructions — a `late final`, an
  async factory, a validation step between them — reintroduces the loss with no
  test going red.
- **The class is public and documented for direct construction**, the same
  property that made the `RpcWebSocketChannel.close()` deadlock reachable. That
  file's own comment already names this hazard: *"a broadcast controller DROPS
  events that arrive before the frame channel subscribes, where this one buffers
  them"* — it chose single-subscription for the hop below for exactly this
  reason.
- Round 240 fixed the resilience hop, where the loss WAS reachable and measured
  (0 frames against 1). This is the same shape one layer down.

## Owner decision

**Ship the buffered controller anyway** (round 247). Make `_incomingCtl` a
`BufferedBroadcastController` with the transport's own `sizeOf`, like every
other inbound controller in the library, accepting that it lands on a hot path
with no test that would go red without it.

The canary rule is not waived, it is answered honestly in the record: there is
no witness because the loss is unreachable today, and the change buys the
invariant instead of the ordering coincidence. The round that carries this out
says so in `## Canary` rather than inventing one, and must still show the other
tests green under the change.

## What would close it

Either a measurement that reaches the window (a construction path with an await
between channel and transport — if one exists, it is a finding, not a lead), or
switching `_incomingCtl` to `BufferedBroadcastController` with the transport's
own `sizeOf` and accepting that the change ships without a witness. The second
needs the owner: it is a pre-emptive change to a hot path.
