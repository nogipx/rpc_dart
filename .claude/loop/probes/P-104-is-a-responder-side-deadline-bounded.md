---
file: packages/core/rpc_dart/.dart_tool/probe/responder_deadline_is_bounded.dart
round: 451
commit: c60943e2
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_streams.dart]
status: valid
---

# P-104 — is a responder-side deadline bounded, and by WHAT?

## Why it exists

B-73 asks three questions in order and only the third decides anything: does a
responder-side call with a deadline get torn down; by what; and does the consumer
see an error or a clean end.

## The harness, and the one thing that makes it work

A server-stream handler that yields every 100 ms against a 300 ms deadline, so the
item count IS the clock. Two handler variants, because a token cancellation is a
REQUEST and the arms differ in whether it is honoured: one checks the token, one
ignores it and keeps producing.

**The reading that matters is a responder-side LOG record, not the caller's
exception.** `RpcDeadlineExceededException` at the caller is equally consistent
with the responder doing nothing at all: the caller has a deadline timer of its
own, and one `grpc-timeout` header arms both ends. Only `_onDeadlineExceeded`
emits *"exceeded its deadline — cancelling handler"*, so a `LogController` at
`minLevel: internal` passed to `RpcResponderEndpoint` attributes the teardown.

`RpcResponderEndpoint` takes a `LogController`, not a `LogScope`.

## The numbers (round 451)

```
arm                     items  outcome                        RESPONDER
                                                              deadline fired
cooperative, 300 ms         3  RpcDeadlineExceededException   true
stubborn,    300 ms         3  RpcDeadlineExceededException   true
CONTROL, no deadline      100  CLEAN END                      false
```

## Measures

Items delivered, how the caller's subscription ended, whether the handler observed
its token cancelled, the responder's `activeStreams` afterwards, and the two
responder log records — the deadline notice and the reclaim warning.

## Control

The no-deadline arm. 100 items, clean end, and the log line ABSENT — so the
observable discriminates rather than always firing, which is the whole risk with
a log-based reading.

## A void arm, so nobody rebuilds it

Two builds went into a hand-driven responder — no caller endpoint, a request sent
straight down the raw client transport with a `grpc-timeout` header — and it read
`payloads=0` in the timeout row AND its control. The handler never ran; adding
`endStream: true` to the request did not fix it. That is L-15: a void arm reads
exactly like a clean one, and `payloads=0` in the CONTROL is the tell.

## What it does not establish

Nothing about the reclaim backstop: `reclaimed=false` everywhere, because the
token cancellation did reach the handler — a `yield` on a cancelled scope
terminates the stream, so even the uncooperative arm stopped. A handler that
cannot be unwound is a different bench.
