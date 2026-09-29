---
file: packages/core/rpc_dart/.dart_tool/probe/b119_frames_per_unary_call.dart
round: 510
commit: 49d79ed8
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/core/channel_frame.dart]
status: valid
---

# P-148 — how many frames is a unary call, and what are they?

## Why it exists

B-119 is a COST lead — "five frames, three of them JSON metadata" — and a count read
off the source cannot be checked by reading more source. The rig counts frames where
one `send` on the byte channel is exactly one frame, which needs no instrumentation
inside the library.

**Then it prints what each frame IS, and that is what turned a cost item into a
defect.** A count of 4 says nothing; `META+end, META+end, META+end` says the
responder answered one call three times.

## The harness

A byte-level pipe whose two `_Side`s are cross-wired, each counting and decoding
what is written into it, wrapped in `RpcFrameMultiplexedChannel` and then
`RpcChannelTransport`. Real endpoints on top, so the sequence is the real one.

Three details make it readable:

- **The metadata payload is decoded and printed.** It is JSON, and whether a frame
  carries a `methodPath` decides whether the responder treats it as a NEW call — so
  the bytes are the evidence, not the count.
- **The stream id is printed.** Three trailers could be three calls; `s3` three times
  says they are one.
- **One call is made and the counters reset before the measured call**, because the
  first call on a connection pays setup that is not per-call cost.

The arms vary the OUTCOME — succeeds, handler throws, no such method — because the
protocol claim inside the lead is about failures, and a success count says nothing
about them.

## The numbers (round 510)

Before, per call, responder to caller:

```
succeeds        4: window-update, content-type, DATA, grpc-status 0
handler throws  3: window-update, content-type, grpc-status 7
no such method  4: window-update, grpc-status 12, grpc-status 12, grpc-status 12
```

After:

```
no such method  2: window-update, grpc-status 12
```

The other two arms are unchanged.

## Measures

Frames, by direction, decoded. Not time — the lead's latency claim is downstream of
the count, and the count is the thing that can be wrong in an interesting way.

## Control

**The two arms that must NOT change**, and they did not: a successful call and a
handler that throws both keep their exact sequences across the fix. Without them a
change that suppressed trailers generally would look like a success here.

The `no such method` arm is its own control for the *cost* reading: it shows the
lead's "five frames" is wrong in both directions — a success is 7 frames across both
directions, not 5, and 5 of those are metadata, not 3.

## What it establishes, and what it does not

Establishes: one call to an unregistered method produced three end-of-stream trailers
on one stream id, because the responder has three separate `binding == null` sites —
metadata frame, data frame, half-close — and each answered in full.

Also establishes the lead's frame arithmetic is off: 3 out from the caller and 4 back
for a success, 5 of the 7 being metadata.

Does NOT address the lead's other half, the Trailers-Only question for a call that
fails AFTER initial headers have gone out. The `handler throws` arm still shows
`content-type` preceding the trailer, which is precisely the case the lead names and
this round did not change. Nor does it measure latency or CPU, or the JSON-versus-
binary header encoding the lead raises as a wire change.
