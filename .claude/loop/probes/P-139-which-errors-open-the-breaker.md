---
file: packages/core/rpc_dart/.dart_tool/probe/b110_breaker_counts_app_errors.dart
round: 501
commit: 70372049
paths: [packages/core/rpc_dart/lib/src/resilience/circuit_breaker_interceptor.dart, packages/core/rpc_dart/lib/src/resilience/retry_interceptor.dart]
status: valid
---

# P-139 — which errors open the circuit breaker, and what does an open one block?

## Why it exists

Two questions that only make sense together. A classification bug in
`failureOn`'s fallback is harmless if the breaker's state is per method, and it is
serious if one instance covers the endpoint. One rig answers both: the arms vary
the STATUS the failing method throws, and every arm ends with a call to a
DIFFERENT, entirely healthy method on the same endpoint.

Varying the status and not the count is what makes this a probe about
classification. A rig that only counted failures would show the breaker opening
and could not say whether it should have.

## The harness

One channel pair, a two-method contract: `lookup` always throws
`RpcStatusException(<the arm's status>)`, `healthy` always answers. Five failing
lookups — the default threshold — then one `healthy` call. Per arm it prints the
breaker's state, its failure count, and what `healthy` answered.

Each arm also asks what `RpcRetryInterceptor`'s default predicate would make of
the same error, which is the in-repo comparison the finding rests on.

A second file, `b110_what_error.dart`, answers the two questions the regression
test needed and the main rig cannot: an unregistered method comes back as
`RpcStatusException(12)` (a server correctly refusing), and a response codec that
throws arrives as a bare `StateError` with no status at all.

## The numbers (round 501)

Before:

```
NOT_FOUND            breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
INVALID_ARGUMENT     breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
PERMISSION_DENIED    breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
CONTROL cancelled    breaker=closed failures=0  (must be closed/0)
```

After:

```
NOT_FOUND            breaker=closed failures=0  a HEALTHY method then answers: ok:x
ALREADY_EXISTS       breaker=closed failures=0  a HEALTHY method then answers: ok:x
UNAVAILABLE          breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
INTERNAL             breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
RESOURCE_EXHAUSTED   breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
CONTROL cancelled    breaker=closed failures=0
```

## Measures

The breaker's own `state` and `failureCount`, read from the instance, plus the
answer an unrelated healthy method gives. The third is the cost: the first two say
what the breaker decided, only the third says what that decision does to traffic
that had nothing to do with it.

## Control

**`armCancelled()`, and it carries the before-table.** Cancellation was already
excluded before this round, so that arm must read `closed`/`0` while every other
arm reads `open`/`5`. Without it, `open` in every row is equally consistent with a
rig that cannot read anything else — a breaker wired to open on construction would
produce the same table.

The server-health arms are the control for the AFTER table, by the same logic in
reverse: a fix that narrowed the default too far would turn those rows green-
looking (`closed`) and the regression would be invisible.

## What it establishes, and what it does not

Establishes: with `failureOn == null` the fallback counted every non-cancellation
error, so five correct NOT_FOUND answers opened the breaker, and because state is
per interceptor instance the next call to an unrelated method was refused. After
the fix the same five leave it closed and the healthy method answers, while
UNAVAILABLE / INTERNAL / RESOURCE_EXHAUSTED / UNKNOWN / DEADLINE_EXCEEDED still
open it.

Does NOT establish that a per-method breaker is unnecessary. The rig measures the
blast radius of one shared instance and shows it is the whole endpoint; whether
that should be narrowed is a design question the round left to the owner. Nor does
it say anything about the half-open probe path — round 351's territory, untouched
here.
