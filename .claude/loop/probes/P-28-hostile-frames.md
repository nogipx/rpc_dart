---
file: packages/core/rpc_dart/.dart_tool/probe/hostile_frames.dart
round: 278
commit: 7f89eacb
paths: [packages/core/rpc_dart/lib/src/core/channel_frame.dart]
status: valid
---

# P-28 — seventeen hostile frames through the real decoder

A table of named malformed frames, each built with a HAND-WRITTEN 9-byte header
so the declared length can lie, run through `RpcChannelFrame.decodeAll` with the
default policy's limits. Add a row to extend it; the header builder takes
`streamId`, `flags`, `declaredLen` and `payload` independently, which is what
lets a frame contradict itself.

## Measures

What each case produces, sorted into three kinds that matter differently:
a typed `RpcFrameException` (the receive loop handles it), a `0 frames`
short-read (wait for more bytes), or **a leaked `Error`**. The last is the point
of the bench — the receive loop catches `Exception`, so an `Error` from the
decoder reaches the zone, and every guard in `_decodeMetadataPayload` is written
as `on FormatException` or an explicit type test.

## Control

A well-formed metadata frame through the identical call, so a refusal is
attributable to the content rather than to the harness.

```
CONTROL  valid metadata frame     ok: 1 frame, 26 bytes consumed
17 hostile cases                  11 RpcFrameException, 3 short-read,
                                   3 accepted (legal but unusual), 0 Errors
```

> **A case can be refused by the wrong guard.** The first run declared
> `maxMetadata + 1` bytes and delivered three, so
> `data.length < payloadStart + payloadLen` returned a short read and the
> metadata cap was never reached — the row read `ok: 0 frames` and looked like a
> pass. Delivering the payload IN FULL is what makes it test the cap it is named
> for. Whenever a hostile case comes back clean, ask which check actually fired.
