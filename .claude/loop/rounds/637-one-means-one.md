---
round: 637
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness reads each side's outcome for one and for two messages
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 637 — one means one

## Target

B-235, owner's decision: a second message on a side that carries one fails the
call INTERNAL, as gRPC does, on both sides.

## Hypothesis

Every single-message side accepts a second message; each picks its own
survivor and none says so.

## Before

```
two responses + OK      unary caller VALUE one     client-stream caller VALUE two
unary, two requests (one chunk)      server status 0
unary, two requests (two frames)     server status 0
server-stream, two requests          server status 0
```

## Control

One response, one request: answered as before, on every shape.

## Mechanism

RPC-25: four places, four policies. The unary caller kept the first and warned;
the client-stream caller overwrote with the last; the unary responder took
`messages.first`, and a later frame went to the pre-bind buffer, where it waited
for a bind a unary call never makes, charged all the while; the server-stream
responder logged "Ignoring extra request".

## After

`tooManyMessages` (core, hidden from the public surface) is the one answer. The
callers fail the call with it on a second response. The unary responder refuses
two requests in one chunk before running the handler; the pipeline refuses a
later frame on a unary call at once (teardown cancels the handler and drops its
late answer), and no longer buffers it. The server-stream responder answers it
and closes. All seven witness arms green.

Three tests pinned the old tolerance: `client_stream_sink_is_bounded_test.dart`
asserted frames after a unary request were BOUNDED (RESOURCE_EXHAUSTED past 64,
OK at exactly 16), and `the_connection_total_is_bounded_test.dart` filled the
connection that way. They now assert the refusal (INTERNAL on the first extra
frame, OK with none), and the connection-total test still checks that the torn
down stream gives its charge back and an ordinary call follows.

## Canary

The before table is the same witness against the four old policies.

## Gate

`melos run analyze` green, `format` on rpc_dart green. The first `test:unit` was
red on a fourth test of the old tolerance: `a_peer_cannot_flood_the_responder_
log_test.dart` reached the pre-bind refusal's warn-once by flooding a unary call.
That buffer is still reachable -- a request past the byte bound is refused there
-- so the test now drives it that way and still asserts one warning for five
streams. Second `test:unit` green, and `test:web` green in full (exit 0), which also
covers round 636's change.

## Not fixed

A frame that arrives after the unary answer finds the call over and is ignored,
as gRPC's would be. Zero-copy unary (in-process) is not covered by the pipeline
check.

## Links

Lead `../backlog/B-235-a-second-message-on-a-single-message-side-is-accepted.md` — closed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 637]`.
Test `packages/core/rpc_dart/test/streams/a_second_message_on_a_single_message_side_fails_test.dart`.
