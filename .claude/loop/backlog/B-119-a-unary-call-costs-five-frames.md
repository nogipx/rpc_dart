---
status: awaiting owner
round: 510
commit: 49d79ed8
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/core/channel_frame.dart]
probe: P-148
reason: "counting the frames refuted the arithmetic (7 per call, 5 metadata, not 5 and 3) and found a defect the lead does not mention: one call to an unregistered method was answered THREE times. That is fixed. What remains — folding initial headers into the first response, Trailers-Only, a binary header encoding — is protocol and the owner's"
---

# B-119 — a unary call is five frames, three of them JSON-encoded metadata

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The responder sends initial headers BEFORE running the handler, then data, then a trailer; the caller sends metadata then data; on channel transports each metadata frame is `json.encode` + `utf8` + an extra copy.

## The shape

`packages/core/rpc_dart/lib/src/rpc/streams/unary/responder.dart` `handleMessage`: `sendMetadata(initial)`
before `_handler(request)`; `channel_frame.dart:247-259` JSON metadata encoding.

## Why it matters

Latency and CPU per unary call; initial headers also go out for calls that then
fail (no Trailers-Only), which is the case the HTTP transports distinguish.

## Witness a round would build

Unary round trips/s over the frame pair; frames per call counted at the channel.

## Fix sketch

Send initial headers with the first response (or fold them into the trailer for
unary); a binary header encoding is a wire change for the owner.

## Outcome (round 510) — the count was wrong, and it was hiding a defect

Measured at the byte channel, one `send` being one frame, with each frame's metadata
JSON decoded and its stream id printed.

**The arithmetic is off in both directions.** A successful unary call is 3 frames out
and 4 back — 7, not 5 — and 5 of those are metadata, not 3.

**And one call to an unregistered method was answered THREE times:**

```
                before                                          after
no such method  window-update, grpc-status 12 x3 (all on s3)    window-update, grpc-status 12
succeeds        window-update, content-type, DATA, status 0     unchanged
handler throws  window-update, content-type, status 7           unchanged
```

Three end-of-stream trailers on one stream id is a protocol violation anywhere the
peer keeps stream state, and it triples the cost of probing for method names.

The responder has three `binding == null` sites — metadata frame, data frame,
half-close — each calling `_sendGrpcErrorAndCleanup` through `_detached`. That helper
remembers the id SYNCHRONOUSLY, with a comment from an earlier round saying that is
the whole fix. But the guard reading the set also required `_respStreams[id] == null`,
and the teardown runs in the detached `finally` — so the mark was synchronous and the
reader was not. Fixed by gating on set membership alone.

**Printing what each frame IS, rather than counting, is what found it.** A count of 4
for that row is unremarkable beside the success row's 4.

## Owner decision — what is left is protocol

None of the lead's actual subject is done, and all of it is a wire or protocol
question rather than a defect:

1. **Fold initial headers into the first response** (or into the trailer for unary),
   which is the lead's own sketch. Saves one frame per call and changes when a peer
   learns the call was accepted.
2. **Trailers-Only for a failing call.** The `handler throws` arm still sends
   `content-type` before the trailer, so a failure costs two frames where gRPC allows
   one. This is the case the HTTP transports already distinguish, so the behaviour is
   currently inconsistent across transports — which is the strongest argument for
   doing it.
3. **A binary header encoding** in place of `json.encode` + `utf8` per metadata frame.
   A wire change, and the lead already marks it the owner's.

Nothing here was measured for latency or CPU; the frame count is what this round
establishes.

## Owner decision

—
