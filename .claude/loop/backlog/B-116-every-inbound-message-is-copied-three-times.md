---
status: open
release: breaking
round: 507
commit: cc218edc
paths: [packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart, packages/core/rpc_dart/lib/src/core/channel.dart, packages/core/rpc_dart/lib/src/core/parser.dart, packages/core/rpc_dart/lib/src/core/channel_frame.dart, packages/core/rpc_dart/lib/src/core/protocol.dart]
probe: P-145
reason: "the receive path's first copy is CONFIRMED and fixed in round 507 — 389.76 -> 191.45 us per 1 MiB frame end-to-end. It buys that by making a payload a view into the transport's chunk, which is a new requirement on IRpcChannel implementers and needs the owner's sign-off; the send path and the 5-byte-prefix wire question are untouched"
---

# B-116 — channel transports copy each inbound message three or four times, and frame it twice

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Receive: every chunk is appended into `_buf` even when the buffer is empty and the chunk holds whole frames, then `parser.addBytes` copies it (`Uint8List.fromList`), then `sublist` copies the body; send: codec → `RpcMessageFrame.encode` (copy) → `RpcChannelFrame._encode` (copy); the 5-byte gRPC prefix duplicates the channel frame's own length on a message-aligned channel.

## The shape

`packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart:392` `_appendToBuffer(data)`
unconditionally; payloads are views into `_buf`, which doubles its capacity, so a
retained message pins up to 2x its buffer. `parser.dart:39` and `:227`.
`channel_frame.dart:237-245` and `protocol.dart:88-108` on send.
`_encodeMetadataPayload` adds `Uint8List.fromList(utf8.encode(...))` (`:258`).

## Why it matters

Bandwidth-bound copying on websocket, isolate and the frame pair for every
message; http2 additionally re-frames (`emitFramed`) and the processor de-frames
again.

## Witness a round would build

Throughput and allocation per message for 64 B, 16 KiB and 1 MiB unary echo over
the frame pair, before and after.

## Fix sketch

Decode directly from the chunk when `_bufLen == 0`; hand the parser views instead
of copies; consider dropping the gRPC prefix on message-aligned channels (a wire
change — owner decision).

## Outcome (round 507) — the receive path's first copy

**CONFIRMED and fixed.** Measured at the channel, not through an endpoint: a first
bench echoed through `RpcCallerEndpoint` and the JSON codec dominated at 1 MiB, which
would have attributed the time to the wrong layer.

```
per frame                      appended      decoded in place
  64 B    view only              0.75 us         0.66 us
  64 B    copied out             0.29 us         0.27 us
  16 KiB  view only              1.72 us         0.74 us
  16 KiB  copied out             2.40 us         1.05 us
  1 MiB   view only            227.02 us         0.31 us
  1 MiB   copied out           389.76 us       191.45 us
```

**The honest figure is the `copied out` row — 2.0x at 1 MiB** — because that is what a
receiver which RETAINS the message pays. `view only` going 227 -> 0.31 us is the copy
disappearing, not throughput. At 64 B nothing moves, as the shape predicts.

Fixed as the sketch's first clause says: `final fastPath = _bufLen == 0;`, decode out
of the chunk, buffer only the unconsumed tail.

**And the framing of the whole result: no real transport is limited by this.** The old
path sustained 2566 MiB/s end-to-end at 1 MiB; a websocket or TCP link is one to two
orders below. The gain is real, measured and free — it is not a user-visible win.

## Owner decision

**A decoded payload is now a view into the transport's chunk, not into `_buf`.** That
makes a rule for `IRpcChannel` implementers where there was none: a delivered
`Uint8List` must not be written into afterwards, nor reused as scratch for the next
chunk. It is now stated on `IRpcChannel.incoming`.

Every in-repo channel satisfies it — `test:unit` across 21 packages and `test:web` are
the evidence — but this is a contract change that no gate can see, and an external
implementer who reused a buffer would get silent corruption rather than an error.
Three ways to go:

1. **Keep it** (what round 507 shipped). Free 2x at large sizes, documented
   requirement, no in-repo breakage. Needs a CHANGELOG line aimed at transport
   authors.
2. **Keep it, but copy defensively for third-party channels.** There is no way to
   tell them apart, so in practice this means an opt-in flag on the channel — a knob
   nobody will set correctly.
3. **Revert.** One line (`fastPath = false`), and the copy comes back.

**A retained message also pins the whole chunk now**, so a batching transport
delivering a hundred small frames in one chunk keeps all hundred alive if the receiver
keeps one. The lead complains about the mirror of this (`_buf` doubling pins up to 2x),
so the property is relocated rather than new — but it is not measured, since the bench
sends one frame per chunk.

## Still open, not measured here

- **The send path**, which the lead also names: `codec -> RpcMessageFrame.encode ->
  RpcChannelFrame._encode`, plus `_encodeMetadataPayload`'s
  `Uint8List.fromList(utf8.encode(...))`.
- **`parser.addBytes`' `Uint8List.fromList` and the `sublist` of the body.** Round 496
  rewrote the parser's buffering; these two copies were not part of that.
- **The gRPC 5-byte prefix duplicating the channel frame's own length** on a
  message-aligned channel. A wire change, and the lead already marks it the owner's.

## DECIDED in the round-540 review: the shipped change is APPROVED

**Round 507's receive-path fix stands.** Making a payload a view into the transport's chunk is
accepted as a requirement on `IRpcChannel` implementers, on the grounds that the contract is
already written on `IRpcChannel.incoming` in words ("a delivered chunk is handed over, not
lent"), all six shipped transports satisfy it, and the gain is `389.76 -> 191.45 us` per 1 MiB
frame — the only one of the four copies anybody managed to remove.

**A CHANGELOG line is owed and its audience is unusual**: not callers, but anyone who has
written their own `IRpcChannel`. For them this is a behaviour change with a silent failure mode
— reuse a buffer after `add` and data corrupts with nothing to say so. The line has to name the
rule, not the speedup.

## DECIDED 2026-10-02: the 5-byte prefix stays

Only its four length bytes duplicate the channel frame's own length. The flag byte
says whether the message is compressed, and the channel header has nowhere to
carry that. Dropping the prefix would move the flag, fork the parser and the
processors per transport family, and break the wire between versions, for four
bytes a message. What remains here is the send path's two copies and the parser's
two, with no wire change.

**THIS LEAD STAYS OPEN.** The sign-off answers one of three things in it; the send path's two
copies and the 5-byte-prefix wire question are untouched and unmeasured, so the lead keeps them
rather than closing with a remainder nothing routes to.
