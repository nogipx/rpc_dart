---
status: open
round: 583
commit: 680cb188
paths: [packages/core/rpc_dart/lib/src/core/protocol.dart, packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/b147_what_each_rejection_becomes.dart
reason: "cost — the retry is CONFIRMED (413 -> RESOURCE_EXHAUSTED, 3 attempts) and so is the responder reading and discarding the whole body each time; what is unmeasured is what the three uploads cost, and whether any condition behind a 413 is actually transient"
---

# B-222 — a body over the ceiling is uploaded three times

Split out of `B-147` in round 583, which measured the retry and did not take it:
the lead it came from is about a comment and a missing table row, and this is a
question about whether an existing row is right.

## The shape

`grpcStatusFromHttpStatus` maps `413 -> RESOURCE_EXHAUSTED`, and
`RpcRetryInterceptor`'s default predicate retries RESOURCE_EXHAUSTED. Measured in
round 583, end to end:

```
413   status 8 (RESOURCE_EXHAUSTED)   attempts 3
```

A unary call whose message is over `maxMessageLengthBytes` is therefore sent
three times, and each time the responder reads the body to the end and discards
it — bailing out mid-body is what its own comment says it must not do, because
dart:io tears the connection down before the status is flushed.

## Why it matters

The message does not shrink between attempts. Unlike a server-side quota, which
is what RESOURCE_EXHAUSTED usually means and which really is transient, a
message-size refusal is deterministic: the second and third attempts are known
to fail before they are made.

The 413 row's own doc argues the status from the DIAGNOSTIC — RESOURCE_EXHAUSTED
"tells the caller it hit a SIZE it can reduce rather than sent malformed
arguments" — and that argument is about what the caller reads, not about what the
predicate does with it. The two were decided together and only one of them was
reasoned.

## What a round owes this

**Which conditions behind a 413 can change between attempts.** If none can, the
cost is the finding; if some can — a responder whose `maxMessageLengthBytes` is
reconfigured, a proxy's own body limit, a multipart upload — the retry is doing
its job and the lead is REFUTED.

**The cost of the three uploads**, which is the number nobody has: bytes on the
wire and time to the final error for a message at, say, 2x and 10x the ceiling,
against the one-attempt control. The http2 responder answers 413 for the same
condition, so it has the same question.

## Why it is not just "narrow the predicate"

The predicate is public and replaceable, and narrowing the DEFAULT changes
behaviour for every status the table maps to RESOURCE_EXHAUSTED — including a
genuine server-side exhaustion, which is the case the default exists for. The
candidates are therefore: a distinct status for a size refusal, a row change, a
predicate that reads the message, or nothing. Measure before choosing.

## Owner decision

—
