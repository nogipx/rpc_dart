---
status: closed (round 569)
round: 569
commit: 2aaf73d5
release: breaking
paths: [packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart]
probe: P-190
reason: "bench — both halves CONFIRMED at the server and fixed: a cancel for a released id opened `/Unknown/Unknown`, and a second opening frame on a live id stranded the first stream while the count still read 1"
---

# B-175 — http2 caller: a cancel for an unknown id opens a new /Unknown/Unknown stream

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`resetStream` returns false for an id not in `_activeStreams` (finished, cleared by reconnect, reserved but never opened); core then falls back to `sendMetadata(endStream: true)`, and `sendMetadata` always calls `makeRequest` with `methodPath ?? '/Unknown/Unknown'`; a second `sendMetadata` on a live id overwrites the stream and its subscription.

## The shape

`packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart:809, 876-905`.

## Why it matters

Same class as the HTTP/1.1 phantom POST, on narrower windows.

## Witness a round would build

Server-stream call cancelled before its initial metadata goes out; count streams
at the server.

## Fix sketch

Refuse `sendMetadata` without a methodPath on an id with no stream; guard the
overwrite.

## Outcome (round 569) — both halves confirmed at the server, and fixed

`../rounds/569-the-cancel-that-was-a-request.md`. Bench `P-190`.

```
                                        before                        after
cancel after a completed call   [/Svc/Echo, /Unknown/Unknown]   [/Svc/Echo]
a second OPENING frame, live id [/Svc/Slow, /Svc/Again]         [/Svc/Slow]
                                accepted, activeStreams 1       RpcStatusException
```

**The second half is the sharper one**: `_activeStreams[streamId] = stream` overwrote, so the
first stream was stranded with nothing tracking it while the count still read 1 — one number
meaning two different streams before and after.

**Breadth is one instance**: `/Unknown/Unknown` appears twice across every `lib/` — here, and in
HTTP/1.1's comment about having already removed it. The fix copies that sibling's rule: no
methodPath means nothing goes on the wire, because a cancel on this transport is an RST_STREAM and
`resetStream` already sends it.

**The trap worth keeping**: a second `sendMetadata` after an ANSWERING server has ended the stream
takes the no-methodPath branch and reads as fixed while saying nothing about the overwrite. That
case needs a server that never answers (`L-15`).

Not measured: what a real responder does with the phantom `/Unknown/Unknown` call, and the two
other routes to `resetStream == false` the prose names — an id cleared by reconnect, one reserved
but never opened. Both take the same early return by construction rather than by witness.

## Owner decision

—
