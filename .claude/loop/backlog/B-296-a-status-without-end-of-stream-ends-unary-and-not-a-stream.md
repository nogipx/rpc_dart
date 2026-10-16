---
status: closed (round 878)
release: changelog
round: 858
commit: 6c31366f
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/client/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/server/caller.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/r848_channel_response_oracle.dart — P-317
reason: owner — which status a call takes when a peer sends two is a contract choice; unary's is documented as deliberate
rank: 5
---

# B-296 — a status without end of stream ends unary and not a stream

A server that sends one message, grpc-status 0 WITHOUT END_STREAM, then
grpc-status 13 with it:

```
P-317 (channel) and P-326 (http2), the same on both:
  unary  OK value=a     client OK value=a
  stream ERROR 13       bidi   ERROR 13
13 without END, then 0 with it: ERROR 13 on all four
```

Unary and client-stream complete on the first status they see, gated on
nothing ("Deliberately NOT gated on isEndOfStream", in the unary caller,
so a peer that sends its status without the flag is not turned into an
error by `onDone`). The streaming shapes fail on any non-OK status but
end OK only on END_STREAM. A peer that sends two statuses breaks the
protocol, so only a hostile or buggy server reaches this; the cost is that
the outcome depends on the call shape.

Severity S2 — "a status or error type a caller branches on".

## Options

1. The first status wins on every shape (the streaming callers end at an
   OK status without END_STREAM).
2. The status on the END_STREAM frame wins on every shape, and unary waits
   for it (what the unary comment says it avoids).

The streaming rule is `_grpcStatusErrorTransformer` in
`streams/server/caller.dart`, which the bidi caller also applies.

## Owner decision

2026-10-16, revised the same day: option 2, the status on the END_STREAM
frame wins on every shape, as grpc-go does. Unary and client stream wait
for END_STREAM.

The first answer was option 1, taken on a recommendation made without
checking grpc-go. Round 878 implemented option 1 and found two facts that
changed the answer. First, it broke 4 rows of
`a_response_cut_mid_message_is_an_error_test` (http2, rounds 853/858): a
status in headers without END_STREAM, then DATA, delivers the messages, as
grpc-go does, and option 1 dropped them. Second, grpc-go's
`operateHeaders` parses a grpc-status on a non-END_STREAM HEADERS frame but
never uses it; the status is built only on the END_STREAM path. Option 1
was reverted uncommitted.

The constraint: a peer that never sets END_STREAM after its status now
leaves a unary or client-stream call to its deadline instead of ending it.
That reverses the deliberate "not gated on isEndOfStream" in the unary
caller.
