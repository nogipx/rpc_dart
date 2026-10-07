---
status: closed (round 568) — by owner decision, 2026-10-07
round: 568
commit: 86c3cc16
release: breaking
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_common.dart]
probe: P-187
reason: "bench — items 1 and 2 are CONFIRMED on the wire and fixed: the payload never left the process and the send reported success, and `outgoingPumps` was the one map of seven the inline release left behind. Item 3, `_waiters` overtaken by a new `add`, needs a caller that can reach one pump concurrently and no shape in this repo does"
---

# B-221 — a parked send reports success after a peer reset, and the pump outlives the reset

Split out of `B-184` in round 565 rather than left in its `## Not fixed`, because a closed
lead's remainder is routed to by nothing. Two readings from `P-187`, both unvaried.

## 1. The parked send reports success

```
WITNESS  parked=true threw=null
    after reset   {activeStreams: 0, halfClosedLocal: 1, outgoingPumps: 1}
```

`threw=null` is the finding. A peer RST_STREAM cancels the pump's outgoing sink but does not
dispose the pump, so round 558's throw — which fires on `_disposed || _controller.isClosed`
— does not apply: the woken `add` puts the payload into a controller whose sink is already
cancelled, closes it, and returns normally.

**That is round 558's own class on the path 558 did not cover.** Its words: *"Returning
normally here told the caller its payload had been sent when the pump had been disposed
under it, which is silent request truncation — a send that did not reach the peer must not
read as success."* Its arm disposed the pump; this one does not.

**What is NOT established**: whether the payload reaches the wire. P-187 reads the
transport's maps, not the server's bytes, and a RST_STREAM mid-request makes "reached the
peer" ambiguous in a way the disposal case was not — the peer asked for the stream to stop.
So the first arm a round owes this is the server side: does the DATA frame appear after the
reset, and if not, does any caller see an error for it? The caller does learn the call
failed, from the response side; the question is whether a `sendMessage` future resolving
successfully for a frame that went nowhere is worth an error of its own.

## 2. The pump outlives the reset

`outgoingPumps: 1` after the reset in every P-187 arm. The inline release
(`rpc_http2_caller_transport.dart:1223-1229`) clears seven per-stream maps and
`_outgoingPumps` is not one of them; `releaseStreamId` is the only path that disposes a
pump.

Through `RpcCallerEndpoint` this is harmless and measured so: the STACK arm reads
`outgoingPumps: 0`, because the pipeline releases the id when the call ends. For a direct
transport user it is one pump per reset stream until they release the id — the same shape
`reset_stream_releases_its_pump_test.dart` fixed for `resetStream`, in the third of the
three teardown blocks that round compared.

So the question is whether the inline release should dispose it, which is a question about
which of the three blocks owns a pump rather than a bug with a number.

## 3. `_waiters` can be overtaken by a new `add`

Named by `B-184`'s original prose, never one of its three measured claims, and carried here so
closing that lead does not drop it. `RpcHttp2OutgoingPump._waiters` is a plain list woken as a
batch by `_wake()`, so two concurrent `add`s on one stream have no defined order with respect
to each other.

Unmeasured, and possibly not a defect: ordering two concurrent sends on ONE stream is the
caller's to serialise today, and every shape in this repo sends through a single sequence
(`base_processor`'s `_sendSequence`). The round that takes it has to establish a caller that
can reach the pump concurrently at all before measuring what the order does.

## Outcome (round 568) — items 1 and 2 confirmed on the wire, and fixed

`../rounds/568-the-send-that-went-nowhere.md`. Bench `P-187`, extended with a DATA-frame scanner.

```
                               before                  after
WITNESS  threw                 null                    RpcStatusException
         wire                  [(64,false)]            [(64,false)]   unchanged
         outgoingPumps         1                       0
CONTROL  threw                 null                    null
         wire                  [(64,false),(453,false),(517,true)]   unchanged
```

**The payload never left the process.** The server read 64 bytes — the window's worth of the
FIRST send — and never the 512 the parked send carried, while that send returned normally. The
control, differing only by a WINDOW_UPDATE before the reset, delivers all three frames.

**`outgoingPumps` was the only one of seven maps the inline release left behind**, read together
rather than one at a time.

Fixed as two mechanisms: the pump records that its SINK was cancelled — distinct from `_finish()`
closing it from this side — and `add` throws on it; and the inline release disposes the pump.
**The control is what makes the first safe**: `onCancel` does not fire on a clean completion, so
a send that DID reach the peer still reads as success.

`_fcForget` is still not called on that path, where `releaseStreamId` calls it. `fcOutstanding`
read 0 in every arm, so there is no failing arm and nothing was changed on symmetry alone.

## Witness a round would build

For 1: P-187's rig with the server socket's received frames recorded, one arm with the
reset and one without. For 2: P-187's REACH arm with no `releaseStreamId`, over N reset
streams, reading `outgoingPumps`.

## Owner decision

2026-10-07: **close** -- items 1 and 2 were fixed in round 568; item 3 has no
caller in this repository that reaches one pump concurrently.
