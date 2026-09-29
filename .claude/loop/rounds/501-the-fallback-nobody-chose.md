---
round: 501
verdict: FIXED
packages: [rpc_dart]
lens: RPC-08
bench: P-139 — new
commit: yes
---

# Round 501 — the fallback nobody chose

## Target

B-110, seventeenth in the audit's rank: the circuit breaker's default failure
predicate.

Lens RPC-08, shape 1 — *one sibling has X, the other does not*. The siblings here
are not two transports but two interceptors in one directory, both of which
classify an error to decide whether to act on it. `RpcRetryInterceptor` has a
chosen, documented, narrow default (UNAVAILABLE and RESOURCE_EXHAUSTED only, and
its doc says why). `RpcCircuitBreakerInterceptor` had no default at all: a null
`failureOn` fell through to *everything except cancellation*. Reading either file
alone, that is a plausible design. Reading them side by side, one of the two never
had the decision made.

## Hypothesis

With `failureOn == null` a server that correctly answers application errors opens
the breaker, and because state is per interceptor instance it refuses unrelated
methods on the same endpoint.

## Before

```
NOT_FOUND            breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
INVALID_ARGUMENT     breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
PERMISSION_DENIED    breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
CONTROL cancelled    breaker=closed failures=0  (must be closed/0)
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b110_breaker_counts_app_errors.dart`

CONFIRMED, and the cancellation arm is what makes it admissible: it must read
`closed` where the others read `open`, so the rig demonstrably distinguishes the
two states. Five correct NOT_FOUND answers — a working server doing its job — took
the whole endpoint down for 30 s.

## Mechanism

```dart
final counts = error is! RpcCancelledException &&
    (failureOn == null || failureOn!(error));
```

`failureOn == null ||` reads as "no filter configured, so admit", which is the
right default for a filter and the wrong one for a classifier. A breaker is not
filtering a stream of failures, it is asking *which errors are evidence about the
server*, and "all of them" is an answer nobody chose — it is what the `||` does
when the field is absent.

Two independent facts made it expensive. The classification is wide, and the state
is per interceptor instance rather than per method, so the wide classification's
cost lands on methods that never failed.

## After

```
NOT_FOUND            breaker=closed failures=0  a HEALTHY method then answers: ok:x
ALREADY_EXISTS       breaker=closed failures=0  a HEALTHY method then answers: ok:x
UNAVAILABLE          breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
INTERNAL             breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
RESOURCE_EXHAUSTED   breaker=open   failures=5  a HEALTHY method then answers: BREAKER OPEN
CONTROL cancelled    breaker=closed failures=0
```

The fix is a named default, `_isServerHealthFailure`: UNAVAILABLE,
RESOURCE_EXHAUSTED, INTERNAL, UNKNOWN, DEADLINE_EXCEEDED — plus *anything that is
not an `RpcStatusException` at all*, because an error with no status is not an
application answering, it is something failing. An explicit `failureOn` still
replaces it wholesale.

**It is deliberately WIDER than the retry interceptor's set, and the difference is
the point of comparing them.** A breaker asks "is this endpoint in trouble", a
retry asks "is another attempt worth making". INTERNAL and UNKNOWN — what a
crashing handler produces — answer the first and not the second. Copying the
sibling's set would have been the wrong conclusion from the right observation.

Regression: `test/resilience/the_breaker_counts_server_health_only_test.dart`,
5 WITNESS arms and 7 GUARDs.

## Canary

`return true;` restored at the top of `_isServerHealthFailure`, in place. Exactly
the 5 WITNESS arms fail, each on the state it names:

```
NOT_FOUND         Expected: closed   Actual: open
INVALID_ARGUMENT  Expected: closed   Actual: open
PERMISSION_DENIED Expected: closed   Actual: open
ALREADY_EXISTS    Expected: closed   Actual: open
UNIMPLEMENTED     Expected: closed   Actual: open
```

All 7 GUARDs stay green under the ablation, which is the half that matters here:
they are satisfied by the OLD behaviour too, so they cannot be what the canary
moves — they exist to fail if a future narrowing goes too far.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS (rpc_dart 1722 tests);
`melos run license:check` compliant. `format:check` failed once, on this round's
own new test file, and was fixed by `fvm dart format` before the re-run went
SUCCESS.

The two pre-existing breaker suites pass unchanged — both configure `failureOn`
explicitly, which is why narrowing the default did not touch them, and also why
this defect survived: everything that tested the predicate supplied one.

## Not fixed

**Two of the round's own GUARD arms were wrong before they were right, and the
reason is worth keeping.** The first draft asserted that calling an *unregistered*
method counts as a failure, on the assumption it times out. It does not: the
responder answers `RpcStatusException(12)` immediately. Under the new default that
is benign — correctly, because a caller with a typo in a method name must not take
the endpoint down — so the arm was inverted into a fifth WITNESS. The real "no
status" arm needed an error that carries none, and a response codec that throws
supplies it: a bare `StateError`. **The lesson is in the method: a guard arm has to
be measured like a witness.** Asserting what an error *ought* to be is how a test
ends up guarding a path the code never takes.

**Per-method breakers: not done, and the bench says what it would buy.** The
lead's sketch ends "consider per-method breakers", and P-139's third column is
exactly that measurement — one unhealthy method still costs every other method on
the endpoint. Narrowing the classification removes the cheap way to trigger it; it
does not remove it. That is an API change (a keying function, or one interceptor
per method) with a policy question inside it, and it is the owner's.

## Links

Lens RPC-08. Bench P-139 (new). Lead B-110 (closed). The sibling this round read
against is `retry_interceptor.dart`, whose default was chosen in 3.4.0 and whose
CHANGELOG entry for the zero-copy path names `failureOn` as a reader of the same
status. Round 351 owns the half-open probe path, untouched here.
