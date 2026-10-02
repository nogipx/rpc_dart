---
round: 614
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: P-218 — new
budget: probes 4/5, canaries 3/5
commit: yes
release: changelog
---

# Round 614 — the two copies left

## Target

B-116 items 1 and 2, which the owner asked for on 2026-10-02, the 5-byte prefix
staying. The send path copies a message twice (`RpcMessageFrame.encode`, then
`RpcChannelFrame._encode`). The parser copies it twice (`addBytes`, then the body
`sublist`).

## Hypothesis

Each pair can lose one copy without a wire change. In the parser, a chunk
holding whole messages needs no buffer. On send, the gRPC frame can be built
with room for the channel header in front of it.

## Before

```
1 MiB     parse 206.75 us   parse+keep 389.33 us   send 391.94 us
16 KiB    parse   1.03 us   parse+keep   1.95 us   send   1.67 us
64 B      parse   0.08 us   parse+keep   0.08 us   send   0.04 us
```

`P-218`, both changes switched off in place.

## Control

The 64 B row. A first send-path version registered EVERY frame in an
`Expando`, and 64 B sends went `0.10 -> 0.33 us`, a regression on the common
size. The threshold below is what that measurement bought.

## Mechanism

Parser: every chunk was appended to `_bytes` and each body sliced out with
`sublist`, so a whole message in one chunk was copied twice. Send: the gRPC frame
was a fresh list, and the channel frame was another, with the message copied in.

## After

```
1 MiB     parse 0.09 us   parse+keep 256.50 us   send 232.03 us
16 KiB    parse 0.09 us   parse+keep   1.04 us   send   0.87 us
64 B      parse 0.07 us   parse+keep   0.07 us   send   0.04 us
```

Parser: when nothing is buffered, it decodes straight out of the chunk and
each body is a view into it. Only an incomplete tail is buffered, and a body
assembled from the buffer is still copied, because the buffer is compacted and
reused. This is the same shape round 507 gave `RpcFrameMultiplexedChannel`, under
the same rule `IRpcChannel.incoming` states.

Send: `RpcMessageFrame.encode` reserves 9 bytes in front of a frame of 4096
bytes or more (`frame_headroom.dart`, not exported). `RpcChannelFrame._encode`
writes its header there instead of copying. Ownership is proven by an `Expando`
on the exact view `encode` returned, and claimed once, so a frame sent twice
copies the second time. `_encodeMetadataPayload` also lost a
`Uint8List.fromList` around `utf8.encode`, which already returns a `Uint8List`.

## Canary

1. Parser in-place path off: `a whole message in one chunk is a view into it`
   fails, `Expected: <99>, Actual: <1>` (the body was a copy), and so does the
   two-and-a-partial arm.
2. Headroom off: `a large gRPC frame is not copied into its channel frame`
   fails, `Expected: <7>, Actual: <0>`.
3. Claim not cleared: `the same gRPC frame sent twice keeps the first header`
   fails, `Expected: <3>, Actual: <5>`. The second send rewrote the first
   frame's stream id.

## Gate

`melos run analyze`, `melos run test:unit --no-select` (rpc_dart +1919,
websocket +257, http2 +275, isolate +93), `melos run format:check`,
`melos run license:check`, `melos run test:web` (the `Expando` and the views
run under dart2js too) — green.

## Not fixed

The codec's own output is one more copy below the gRPC frame (`serialize`, then
`encode` copies it in), and HTTP/2 re-frames through `emitFramed`. Both would
need the codec to write into a buffer it does not own. The lead closes on the
owner's scope: the prefix stays, items 1 and 2 are done.

## Links

Lead `../backlog/B-116-every-inbound-message-is-copied-three-times.md` — closed.
Bench `../probes/P-218-the-parser-and-send-copies.md` — new.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 614]`.
Tests `packages/core/rpc_dart/test/core/the_parser_does_not_copy_a_whole_chunk_test.dart`,
`packages/core/rpc_dart/test/core/a_channel_frame_reuses_the_grpc_frame_test.dart`.
