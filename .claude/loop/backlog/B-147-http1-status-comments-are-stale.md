---
status: closed (round 583)
round: 583
commit: 8253fe8a
paths: [packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/core/rpc_dart/lib/src/core/protocol.dart]
probe: packages/transport/rpc_dart_http/.dart_tool/probe/b147_what_each_rejection_becomes.dart
reason: "CONFIRMED: the comment names a function that does not exist and the wrong status, and its CONCLUSION survives anyway. The behaviour half is real and fixed -- 408 had no row and was therefore final"
---

# B-147 — HTTP/1.1 comments describe a status table core no longer has

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`:404-409` cites `_httpStatusToGrpcCode` and 400 → INVALID_ARGUMENT; core's `grpcStatusFromHttpStatus` maps 400 → INTERNAL and 405/408/415 → UNKNOWN, so a metadata violation reaches the caller as INTERNAL and a body timeout as UNKNOWN (not retryable).

## The shape

`packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart:404-409`, `packages/core/rpc_dart/lib/src/core/protocol.dart:211-220`.

## Why it matters

The comment argues a retry semantics the code no longer has; 408 → UNKNOWN is a
real behaviour question: whether a body timeout should stay UNKNOWN is a decision for the shared table.

## Witness a round would build

Read.

## Fix sketch

Fix the comment; decide whether 408 should be UNAVAILABLE/DEADLINE_EXCEEDED in
the shared table.

## Measured — round 583

The lead asks for a read. Reading answers which status the table returns and
nothing about what a caller DOES with it, and the comment's whole argument is
about the second. `P-203` reads both, for every status `_reject`'s call sites can
answer with:

```
http  status  attempts  what it stands for
400   13      1         metadata violation, or a body that would not read
405    2      1         not a POST
408    2      1         the body did not arrive inside bodyReadTimeout
413    8      3         request body over maxMessageLengthBytes
415    2      1         content-type is not application/grpc
503   14      3         transport closed, or maxActiveStreams reached
```

**The comment half: CONFIRMED, and weaker than filed.** It names
`_httpStatusToGrpcCode`, which does not exist, and `400 -> INVALID_ARGUMENT`,
which is wrong. But the thing it was arguing — that choosing 400 over 413 would
invert the retry semantics — is TRUE as written, because INTERNAL and
INVALID_ARGUMENT are both final:

```
RESOURCE_EXHAUSTED 8  attempts 3
INVALID_ARGUMENT   3  attempts 1
INTERNAL          13  attempts 1
```

So the stale sentence never misled anyone about the decision it justified. Fixed
to name the real function and the real status.

**The 408 half: CONFIRMED and fixed.** `grpcStatusFromHttpStatus` is grpc-go's
table plus the rows something here really produces, and its own doc says so — 408
is produced here and had no row, so it took `_ => unknown`, which the default
predicate treats as final. A stalled upload is the textbook transient failure and
was the one rejection a caller could not retry. Now `408 -> unavailable`:

```
408   14      3
```

UNAVAILABLE, not the lead's other candidate DEADLINE_EXCEEDED: that names the
CALLER's own budget, which rpc_dart carries in `grpc-timeout` and reports itself,
and it is not retryable either — so it would have changed the word and not the
behaviour.

**405 and 415 were considered and deliberately left without rows.** Both are the
caller's own bug and `unknown` already makes them final, so a row for either
improves the diagnostic and changes nothing. The reason is now written beside the
table, because "three statuses this responder emits are missing" is the question
the next reader will ask.

## What this lead does NOT cover

- The HTTP/2 caller reads the same table for a non-200 `:status` and now inherits
  the 408 row from a foreign proxy. Intended — the table exists because the two
  transports disagreeing on retryability was the original defect — but reasoned
  rather than measured.
- Whether 413's own retry is worth its cost: `B-222`.

## Owner decision

—
