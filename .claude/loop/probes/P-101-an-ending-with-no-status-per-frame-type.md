---
file: packages/transport/rpc_dart_http2/.dart_tool/probe/missing_trailers.dart
round: 447
commit: 4ff4e346
paths: [packages/transport/rpc_dart_http2/lib/**, packages/core/rpc_dart/lib/src/endpoint/**, packages/core/rpc_dart/lib/src/rpc/streams/**]
status: valid
---

# P-101 — an ending with no status, per FRAME TYPE

## Why it exists

Round 429 guarded http2's DATA path: END_STREAM on DATA does not end the gRPC
call unless a status has already arrived. B-86 says the HEADERS path is a bare
`isEndOfStream: message.endStream`. The variable is therefore the FRAME TYPE the
ending rides on, holding the missing status fixed.

Extends the round-429 probe rather than a new file: it already had the raw HTTP/2
server, and the two arms it lacked are two more `switch` cases.

## The arms

Raw frames over a `ServerSocket`, because only a foreign server can end a stream
without a status. Two messages first in every arm, so a loss is visible as a
COUNT and not just as an outcome.

```
(a) one message + END_STREAM on DATA, no status
(b) no message + END_STREAM on DATA, no status
(c) no message, connection dropped
(d) two messages + END_STREAM on DATA, no status      <- 429's witness
(e) two messages + trailers HEADERS, END_STREAM, NO grpc-status   <- B-86
(f) two messages + trailers HEADERS, END_STREAM, grpc-status: 0   <- control
```

**Print the label BEFORE running the arm.** `'${await run(x)}'` evaluates before
the `say`, so each arm's transport trace appeared under the PREVIOUS arm's
heading — which is how the first reading of (e) looked like it carried a status.

## The numbers (round 447)

```
              before fix                          after fix
(d) DATA      status 14 after 2 items             unchanged
(e) HEADERS   CLEAN END after 2 items, NO ERROR   status 14 after 2 items
(f) control   CLEAN END after 2 items             unchanged
```

The transport trace is what names the mechanism, and (e) reproduces the DATA
path's own documented failure line for line:

```
before:  payload=false end=true  grpc-status=-    <- closes the consumer
         payload=false end=true  grpc-status=14   <- synthesised, too late
after:   payload=false end=false grpc-status=-    <- held back
         payload=false end=true  grpc-status=14   <- becomes the ending
```

## Measures

How the caller's `await for` terminated: the item COUNT and whether an error
arrived. Plus the transport-level trace of `payload / end / grpc-status` per
emitted message, so a loss is attributed to a hop rather than guessed at.

## Control

Three, and they answer different objections.

1. **(f), the same frame type WITH a status** — reads a clean end after 2 items,
   before and after. So the fix does not simply stop ending streams, and (e) is
   about the missing status rather than about trailers.
2. **(d), the same missing status on the OTHER frame type** — already guarded,
   already raising. (d) against (e) is the sharpest pair in the table: identical
   malformation, different frame, opposite outcomes.
3. **P-97's shape at the CORE boundary**, measured separately in
   `packages/core/rpc_dart/.dart_tool/probe/clean_end_without_a_status.dart`:
   over `RpcChannelTransport` an ending with no status raises in all three
   variants (bare end, bare end with no payloads, trailers carrying other
   headers), with a status-trailer control reading NO ERROR. That is what
   establishes the gap is http2-LOCAL and not core's — and it is the arm that
   refuted the owner's decision.

## What it establishes, and what it does not

Establishes: on http2 an ending that rides on a HEADERS frame with no
grpc-status was silent data loss, and the DATA path's guard did not cover it.

Does not establish anything about the HTTP/1.1 caller, which B-86 also names as
unproven. Its trailer path was not exercised here.

## Reading

rpc_dart_http2 — holds the missing grpc-status fixed and varies the FRAME TYPE
the ending rides on. Extends round 429's raw-HTTP/2 probe with two cases
rather than building a server again. **Three controls**: the same frame type
with a status (so the fix did not just stop ending streams), the same
malformation on the already-guarded DATA path (the sharpest pair in the
table), and the shape measured at the CORE boundary, which is what proved the
gap http2-local and refuted the owner's decision. **Trap**: print the label
BEFORE the arm — `'${await run(x)}'` evaluates first, so each trace lands
under the previous heading, which is how the first reading looked like a
passing arm
