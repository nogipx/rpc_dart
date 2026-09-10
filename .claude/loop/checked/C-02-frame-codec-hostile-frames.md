---
round: 278
commit: 7f89eacb
paths: [packages/core/rpc_dart/lib/**, packages/transport/rpc_dart_websocket/lib/**]
scope: [core, websocket]
---

# C-02 — The frame codec against hostile frames

**Re-measured in round 278.** Until then this record read, in full: *"A battery
of nine malformed frames. The codec is clean."* It named none of the nine, gave
no numbers, and had not been re-run since round 46 while six files under its
paths changed. Below is the battery, by name, through
`RpcChannelFrame.decodeAll` — the entry point the channel's receive loop uses —
with the default policy's limits.

    CONTROL  a valid metadata frame            ok: 1 frame, 26 bytes consumed

    header shorter than 9 bytes               ok: 0 frames, 0 consumed
    declared length 0xFFFFFFFF                RpcFrameException: payload too large
    declared length just over the cap         RpcFrameException: payload too large
    metadata frame just over its own cap      RpcFrameException: metadata too large
    declared longer than delivered            ok: 0 frames, 0 consumed
    stream id 0xFFFFFFFF                      ok: 1 frame, 12 consumed
    stream id 0                               ok: 1 frame, 12 consumed
    all flag bits set (0xFF)                  ok: 1 frame, 11 consumed
    metadata: invalid UTF-8                   RpcFrameException
    metadata: malformed JSON                  RpcFrameException
    metadata: JSON is not an object           RpcFrameException
    metadata: methodPath is not a string      RpcFrameException
    metadata: headers is not a list           RpcFrameException
    metadata: header entry is not a pair      RpcFrameException
    metadata: header value is not a string    RpcFrameException
    metadata: 20000-deep nesting              RpcFrameException
    metadata: 4000 headers in the byte cap    ok: 1 frame, 40016 consumed

**Eleven typed refusals, three "wait for more bytes", three legal-but-unusual
frames accepted, and NOT ONE leaked `Error`.** That last column is the one worth
having: the receive loop catches `Exception`, so an `Error` escaping the decoder
reaches the zone, and every guard in `_decodeMetadataPayload` is written as
`on FormatException` or an explicit type test.

**Depth is the case the old record cannot have covered**, and it is the one that
could have leaked: a `StackOverflowError` is an `Error`. 20000 nested arrays
inside the 64 KiB metadata cap are refused as a malformed header entry, because
Dart's JSON decoder keeps an explicit stack rather than recursing.

## What is accepted, and where the next bound is

`stream id 0`, `0xFFFFFFFF` and unknown flag bits are all decoded. That is
correct here — the codec's job is framing, and peer-chosen stream ids are
`../checked/C-04-peer-chosen-stream-ids.md`'s subject — but it means the codec
is not where an id is judged.

The 4000-header row is the same shape one layer down: **the codec bounds
metadata by BYTES and by nothing else.** `maxHeaders` is a policy field enforced
above, so every `RpcHeader` and both its Strings exist before anything counts
them. Bounded per frame by the 64 KiB cap — roughly 6500 headers, order 1 MiB of
objects, ~16x the wire — and refused immediately afterwards. Recorded rather
than pursued: the amplification is bounded and the layer above does refuse.

## Control

A well-formed metadata frame through the identical call: accepted, 26 bytes. So
every refusal above comes from the content and not from the harness.

Bench `../probes/P-28-hostile-frames.md`.
