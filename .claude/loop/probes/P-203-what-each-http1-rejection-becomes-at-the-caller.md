---
file: packages/transport/rpc_dart_http/.dart_tool/probe/b147_what_each_rejection_becomes.dart
round: 583
commit: 680cb188
paths: [packages/core/rpc_dart/lib/src/core/protocol.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
status: valid
---

# P-203 — what each HTTP/1.1 rejection becomes at the caller

## Why it exists

B-147 says a comment argues its choice of HTTP status from a stale mapping table.
The witness it asks for is "read". Reading answers which status the table returns
and nothing about what a caller DOES with it, and the comment's argument is
entirely about the second — so the probe reads both, per rejection.

It enumerates the six statuses `RpcHttpResponderTransport` can answer with,
which is the list `_reject`'s call sites give: 400, 405, 408, 413, 415, 503.

## The harness

Two columns, both measured rather than derived.

`status` — a `dart:io` `HttpServer` answering one fixed status, called once
through a real `RpcHttpCallerTransport` and `RpcCallerEndpoint`, reporting the
`RpcStatusException` code the application receives.

`attempts` — the DEFAULT `RpcRetryInterceptor` driven on that status with a `next`
that throws it, counting how many times `next` ran. 1 is final, 3 is retried.
Driving the interceptor directly rather than through the endpoint keeps the column
about the predicate and not about the transport's own error handling.

## The numbers (round 583)

Before:

```
http  status  attempts  what it stands for
400   13      1         metadata violation, or a body that would not read
405    2      1         not a POST
408    2      1         the body did not arrive inside bodyReadTimeout
413    8      3         request body over maxMessageLengthBytes
415    2      1         content-type is not application/grpc
503   14      3         transport closed, or maxActiveStreams reached

RESOURCE_EXHAUSTED 8  attempts 3
INVALID_ARGUMENT   3  attempts 1
INTERNAL          13  attempts 1
```

After, the one row that moved:

```
408   14      3         the body did not arrive inside bodyReadTimeout
```

## Measures

The gRPC status an application receives for each rejection, and whether the
default predicate spends another attempt on it.

## Control

**The other five rows are the control, and they do not move.** 400 stays
`13 / 1`, 405 and 415 stay `2 / 1`, 413 stays `8 / 3`, 503 stays `14 / 3` — so
the 408 change is the one table row and not the caller's error path having
changed shape.

**The three named statuses at the bottom are the control for the comment's
claim**: `INVALID_ARGUMENT 3 / 1` against `INTERNAL 13 / 1` is what says the
comment names the wrong status and reaches the right conclusion anyway, because
both are final.

## What it establishes, and what it does not

Establishes the whole table end to end, and that exactly one of the statuses this
library's own responder emits had a retryability the absent-row default got
wrong.

Does NOT drive the responder's rejections itself — each arm fakes the HTTP status
with a plain `HttpServer`, because the conditions behind them need six different
hostile clients and the question is what the CALLER makes of the status. The 408
premise (that the responder really answers it for a stalled body) is pinned by a
raw-socket arm in `a_slow_upload_is_worth_retrying_test.dart` instead.

Does NOT cover the HTTP/2 caller, which reads the same table for a non-200
`:status` and therefore inherits the 408 row from a foreign proxy.

## Reading

rpc_dart + rpc_dart_http — **a TABLE, one row per rejection, with two columns
because the lead's argument is about the second**: the gRPC status an
application receives, and how many attempts the default retry predicate
spends. `400 13/1, 405 2/1, 408 2/1, 413 8/3, 415 2/1, 503 14/3`, and 408
becomes `14/3`. The status column alone cannot grade a claim about retry
semantics, and the attempts column alone cannot say which rejection it belongs
to. Five unmoved rows are the control; the three named statuses at the bottom
(`INVALID_ARGUMENT 3/1` against `INTERNAL 13/1`) are the control for the
comment's claim, and they are what showed its conclusion never rested on its
wrong premise. Fakes each HTTP status with a plain `HttpServer` rather than
driving six hostile clients; the 408 premise is pinned by a raw-socket arm in
the suite instead
