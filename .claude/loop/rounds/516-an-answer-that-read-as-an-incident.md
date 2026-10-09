---
round: 516
verdict: FIXED
packages: [rpc_dart]
lens: RPC-23
bench: P-153 — new
commit: yes
severity: S3
---

# Round 516 — an answer that read as an incident

## Target

B-124's other half, taken on round 515's own recommendation: the levels, not the
flooding.

Lens RPC-23, still pointed at a rule rather than a comment. `CLAUDE.md` governs when
a warning fires; what this half is about is what an `error` record MEANS, which the
code answered inconsistently with its own status taxonomy.

## Hypothesis

`UnaryCaller` logs a failed call at `error` twice, and the responder logs every
handler failure at `error`, so an application NOT_FOUND reads as an incident on both
sides.

## Before

```
                               caller   responder
a handler throws NOT_FOUND        2          1
a call that succeeds              0          0    <- control
a handler throws INTERNAL         2          1    <- control
a handler throws StateError       2          1    <- control
```

The caller's two, for one ordinary answer, from different sites:

```
error  rpc.caller.UnaryCaller  gRPC error: 5 - no such record [streamId: 1]
error  rpc.caller.UnaryCaller  Unary call /Svc/missing failed [streamId: 1]
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b124b_application_error_logging.dart`

**CONFIRMED, exactly as filed.** Three `error` records for a server answering
correctly.

## Mechanism

Three sites logged at `error` on the shape of the control flow rather than on the
meaning of the status: `unary/caller.dart` at the non-OK trailer AND again in the
surrounding `catch`, and `unary/responder.dart` in its handler `catch`. A status is
how a gRPC handler SAYS things — NOT_FOUND is the documented way to report a missing
record — so "the handler threw" and "something is broken" are different facts and only
the second is an incident.

## After

```
a handler throws NOT_FOUND        0          0
a handler throws INTERNAL         2          1    <- unchanged
a handler throws StateError       2          1    <- unchanged
```

`RpcStatus.isFault` names the codes that mean something broke — UNKNOWN, INTERNAL,
UNAVAILABLE, DATA_LOSS — and the three sites consult it. A throw carrying no status is
treated as a fault, because an unclassifiable failure is not an application answering.

**It is deliberately NARROWER than `RpcCircuitBreakerInterceptor`'s server-health set
from round 501**, which also counts DEADLINE_EXCEEDED and RESOURCE_EXHAUSTED. A
breaker asks "is this endpoint in trouble"; this asks "did something break". A slow or
throttled server is not broken, and a log line saying so is noise. A guard pins the
difference so a later edit cannot "unify" them and start paging on a timeout.

The caller's second site now fires only for a fault or a status-less throw, which is
what removes the duplication for the ordinary case.

Regression: `test/logger/an_application_status_is_not_an_incident_test.dart`,
2 WITNESS and 4 GUARD.

## Canary

`isFault` made to return true for everything. Both WITNESS arms fail —
`Expected: empty, Actual: [...]` — along with the classification guard, while all
three fault guards hold.

Those fault guards are the load-bearing ones: **silencing every log would pass both
witnesses perfectly**, and INTERNAL plus a bare `StateError` are what stop that.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run format:check` SUCCESS; `melos run license:check` compliant.

`test:unit` went red once on `handler_concurrency_limit_test`'s *a handler keeps its
slot after its call is abandoned* — a timing-sensitive abandonment test, which passed
alone and passed on a full re-run. Consistent with B-196, and this round's change is
logging levels only, which cannot move a handler slot.

## Not fixed

**The caller still logs twice for a genuine fault**, and the after-table says so:
`caller 2` for INTERNAL. The two records are not pure duplicates — one carries the
status and message, the other the method path and a stack trace — so collapsing them
would lose something, and doing it properly means deciding which site owns the
report. Left undone rather than done silently.

**The streaming shapes are untouched.** `StreamProcessor.sendError` logs every status
sent at `error` and is named in the same lead; only the unary paths were varied.

**B-124's flooding half remains unverified**, as round 515 left it. This round
deliberately took the tractable half and did not revisit the frames that never reached
the pipeline.

## Links

Lens RPC-23. Bench P-153 (new). Lead B-124 (the level half closed; flooding still
open). Round 515 chose this half and supplied the counting method. Round 501's
`_isServerHealthFailure` is the sibling classification this one is deliberately
narrower than.
