---
round: 583
verdict: FIXED
packages: [rpc_dart, rpc_dart_http]
lens: RPC-25
bench: P-203 — new
budget: probes 1/5, canaries 2/5
commit: yes
release: changelog
---

# Round 583 — the row the table was missing

## Target

`B-147` — a comment in the HTTP/1.1 responder cites `_httpStatusToGrpcCode` and
`400 -> INVALID_ARGUMENT`, and core's table says otherwise. Filed **high**
confidence as a `cost` lead, with "Read" as its witness.

Taken because its `## Why it matters` names a second thing that is not a comment:
*"408 -> UNKNOWN is a real behaviour question"*. A round that only fixed the
comment would have left that where nothing routes to it.

Lens RPC-25 in its round-498 form: a doc that enumerates its own exceptions is a
list with N entries and an invitation to find the others. `grpcStatusFromHttpStatus`
says *"Two rows are kept beyond grpc-go's, each because something really produces
it"* — so enumerate what this library's responders really produce and check each.

## Hypothesis

The comment's premise is wrong and its conclusion is right. Separately, the
statuses rpc_dart's own responder emits are not all in the table, and for at
least one of them the absent-row default changes retryability.

## Before

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

Probe: `packages/transport/rpc_dart_http/.dart_tool/probe/b147_what_each_rejection_becomes.dart`.

**The comment is wrong about the status and right about the consequence.** It says
400 maps to INVALID_ARGUMENT; it maps to INTERNAL. Both are `1 attempt`, so the
argument it was making — that 413 and 400 invert the retry semantics, `3` against
`1` — survives its own false premise intact. That is the whole of the lead's filed
claim, and it is a comment fix.

**Three of the six statuses this responder emits have no row**: 405, 408, 415,
all falling to `unknown`. Two of them are the caller's own bug and `unknown`
already makes them final, which is correct. The third is a stalled upload.

## Mechanism

`grpcStatusFromHttpStatus` is grpc-go's `HTTPStatusConvTab` plus the rows
something here really produces, and its own doc says so. 408 is produced here —
`bodyReadTimeout` expiring is a `TimeoutException`, which the body-read catch
answers with 408 — and had no row, so it took the `_ => unknown` default. The
default predicate retries `unavailable` and `resourceExhausted` and nothing else.

A slow or stalled upload is the textbook transient failure, and it was the one
rejection a caller could not retry.

## After

```
408   14      3         the body did not arrive inside bodyReadTimeout
```

Every other row unchanged. UNAVAILABLE rather than DEADLINE_EXCEEDED, the lead's
other candidate: DEADLINE_EXCEEDED names the CALLER's own budget, which rpc_dart
carries in `grpc-timeout` and reports itself, and it is not in the retryable set
either — so it would have changed the word and not the behaviour.

405 and 415 are left without rows, and the reason is now written beside the
table: a row for either would improve the diagnostic and change nothing, because
`unknown` is already final and that is where they belong.

## Canary

```
A. the 408 row removed
     WITNESS a 408 is retried, not reported final
       Expected: <14>
         Actual: <2>

B. the 400 row set to INVALID_ARGUMENT, making the old comment true
     GUARD the gRPC table rows are untouched
       Expected: <13>
         Actual: <3>
```

B is the canary for the half that is a comment: a comment cannot be ablated, so
what is ablated is the code the corrected sentence now describes.

**And B tells the round something its own fix did not depend on.** Under B, *GUARD
the statuses that must stay final still are* still PASSES — INVALID_ARGUMENT is
non-retryable too — which is the measurement that the comment's conclusion never
rested on its wrong premise.

## Gate

```
melos run analyze                SUCCESS   21 packages + rpc_dart_wasm
melos run test:unit --no-select  SUCCESS   15 packages; rpc_dart_http +196
melos run format:check           SUCCESS   0 changed
melos run license:check          SUCCESS   2212 / 2212, REUSE compliant
```

`rpc_dart +1876 ~1` and `rpc_dart_http2 +275`, both unchanged, are what cover a
change to a table those two packages share.

## Not fixed

**The HTTP/2 caller inherits the 408 row and no arm drives it.** It reads the same
table for a non-200 `:status`, so a foreign proxy answering 408 is now retried
there too. That is the intended consequence — the table exists because the two
transports disagreeing on retryability was the defect it was built to fix — but it
is reasoned, not measured.

**413 is retried and a too-large body will be too large again.** Three uploads of
an over-limit message, each read and discarded by the responder's ceiling. The
413 row's doc argues RESOURCE_EXHAUSTED tells the caller it hit a SIZE it can
reduce, which is about the diagnostic rather than the retry; whether the retry is
worth its cost is a separate question and is filed as `B-216`.

**No arm drives 405 or 415 from a conforming rpc_dart caller**, because it cannot
produce either: the caller hardcodes POST and `application/grpc+proto`. Both rows'
absence was decided by reading what `unknown` already does.

## Links

Lead `../backlog/B-147-http1-status-comments-are-stale.md` — CLOSED.
Lead `../backlog/B-216-a-too-large-body-is-uploaded-three-times.md` — new, the
remainder this round names and does not take.
Bench `../probes/P-203-what-each-http1-rejection-becomes-at-the-caller.md` — new.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [583]`.
Lesson: none. The candidate — "a comment's conclusion can survive its premise" —
is already `L-13`'s subject from the other side, and canary B is the reading.
