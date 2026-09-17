---
file: packages/core/rpc_dart/.dart_tool/probe/client_stream_short_read.dart
round: 369
commit: 5a22ff67
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/**, packages/core/rpc_dart/lib/src/rpc/streams/server/**]
status: valid
---

# P-60 — what the caller is told when the other side stops reading

## Why it exists

The owner's stated use for client-stream is **resumable upload of large,
CDC-chunked files**, where re-sending the whole file is the thing to avoid. That
makes one question decisive: can the caller tell *"the handler saw all of my
messages"* from *"it saw some of them"*? The same question is put to
server-stream, where the side that stops reading is the CONSUMER instead.

## Measures

Two numbers, both where an APPLICATION can read them, not from a private field:

- how many requests the handler was actually given, counted in the handler
- what the caller was told — the exception type, or `OK`

Plus `DROPPED`-level error records off a `LogController` attached to the
responder endpoint, to separate a real diagnostic from silence.

## Control

Three, all in the same run:

- **`fullRead`** — the same method that drains every message. Differs from the
  case under test by exactly one thing, whether the handler breaks out of its
  `await for`. Reports `17 / OK`.
- **`throws`** — a handler that fails. Reports `RpcStatusException`, so the
  bench CAN see a non-OK ending on this path; an `OK` elsewhere means the call
  really was reported successful, not that the probe cannot read a status.
- **server-stream `emits`** — the mirror shape. Its consumer cancels after 3 of
  17 and the handler stops, which is the correct answer and shows the two shapes
  genuinely differ rather than the bench being blunt.

## The numbers (round 369)

```
                    sent  handler got  caller told             DROPPED logged
shortRead            17        3       OK                            0
shortHold            17        3       OK                            0
fullRead  (control)  17       17       OK                            0
throws    (control)  17        0       RpcStatusException            0
server-stream: consumer read 3 of 17, handler stopped
```

`shortHold` holds the answer 400 ms after breaking, so the stream state is still
alive while the peer keeps sending — the window in which `droppedRequests` is
supposed to be reachable. It is not reached there either.

## What it establishes, and what it does not

Establishes: a client-stream caller cannot distinguish a full read from a
partial one, and no log line is emitted on either path. Server-stream does not
have the defect.

Does not establish: whether `droppedRequests` is reachable by ANY path. Two were
tried and neither reached it; the probe budget (3) was spent before a third
could be built. That is the open half of B-50.

Taken on `RpcChannelTransport.pair()`, so nothing here settles a question made
of latency (P-58's lesson).
