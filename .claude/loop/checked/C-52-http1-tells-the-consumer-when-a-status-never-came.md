---
round: 460
commit: 9f148158
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_caller_transport.dart]
scope: [rpc_dart_http]
---

# C-52 — HTTP/1.1 tells the consumer when a status never came

Bench: P-110, `packages/transport/rpc_dart_http/.dart_tool/probe/a_200_with_no_grpc_status.dart`.

> **Scope**: the unary shape over `RpcHttpCallerTransport` against a 200 with no
> `grpc-status`. The http2 half of the same lead was a REAL defect, fixed in round
> 447 — this negative does not transfer to it or to any other transport.

## The claim that was checked

B-86's remaining half, which round 447 left explicitly unproven: the HTTP/1.1
caller builds its terminal message from a trailer set that only `grpc-status` and
`grpc-message` reach (`:398`), so a response with neither ends the stream with
EMPTY metadata and `isEndOfStream: true` (`:430`) — the same shape that, on http2,
was read as a clean end.

**Reachable, and handled.**

## Reachability, established by reading

The synthesised status at `:345` comes from `grpcStatusFromHttpStatus` and covers
non-2xx only. A **200 with no `grpc-status` anywhere** therefore falls through to
the trailer split, which yields nothing — so the terminal message carries empty
metadata. Any peer answering 200 without the header gets there, a proxy returning
an HTML page among them.

## Measured

```
200, no grpc-status   status=14 "The stream closed before the peer sent a status"
200, grpc-status: 0   RETURNED "answer" -- a clean success
200, grpc-status: 5   status=5
```

## Control

The middle row. The same raw server with the header present returns cleanly, so the
refusal above is the missing status and not the harness — and the third row shows a
non-OK status is reported as itself rather than collapsed into the same UNAVAILABLE.

## Why http2 needed a fix and this does not

The difference is the NUMBER of terminal messages, not the emptiness of the
metadata. http2 emitted TWO end-of-stream messages: the trailers frame with no
status, and then a synthesised one carrying `grpc-status: 14`. The first closed the
consumer, so the second arrived too late and was discarded — measured as
`CLEAN END after 2 item(s)`.

HTTP/1.1 emits exactly ONE terminal message (`:430`), so there is no ordering to
lose. Core's consumer boundary sees an ending with no status and raises, which is
what round 457's core probe found over a channel transport as well.

## What this does not say

Only the unary shape was driven. The streaming shapes go through the same single
terminal emit, which is an argument from the code rather than a measurement.
