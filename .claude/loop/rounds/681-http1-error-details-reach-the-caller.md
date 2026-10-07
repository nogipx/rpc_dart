---
round: 681
verdict: FIXED
packages: [rpc_dart_http]
lens: RPC-25
bench: none — the lead's witness, built as a test
commit: yes
release: changelog
---

# Round 681 — http1 error details reach the caller

## Target

B-248, decided by the owner: route `grpc-status-details-bin` to the trailer
frame in the HTTP/1.1 caller. The lead's witness: `atCapacity` behind
`RpcRetryInterceptor` over http1, attempts counted.

## Hypothesis

The caller splits response headers into an initial frame and a trailer frame,
and only `grpc-status` and `grpc-message` go to the trailer. The status is built
from the trailer, so it carries no details, and the default retry predicate
never sees the `RpcRetryInfo` that makes RESOURCE_EXHAUSTED retryable.

## Before

`packages/transport/rpc_dart_http/test/error_details_reach_the_caller_test.dart`:

```
the details reach the caller      Expected: ['WHY']  Actual: []
a server at capacity is retried   Expected: <3>      Actual: <1>
```

## Mechanism

As hypothesised: `rpc_http_caller_transport.dart`, the header split.

## Fix

`grpc-status-details-bin` joins the two names that go to the trailer frame.

## After

3 of 3 green: the `RpcErrorInfo` arrives, and the at-capacity call runs the
handler 3 times.

## Canary

The fix is one condition; without it the test reads exactly as Before (measured
on the same tree just before the edit). The GUARD -- a status without details
runs the handler once -- is green both ways, so the retry count is not the
predicate retrying everything.

## The verdict questions

1. Yes: Before is the canary; the GUARD is the control.
2. Yes: both rows the lead named.
3. Yes: the caller's exception and the handler's call count.
4. Not zero-valued.
5. Yes, quoted.
6. One cause, two effects, both measured.
7. Yes; the owner's choice.
8. None.

## Gate

`analyze`, `test:unit`, `format:check`, `license:check` green.

## Not fixed

Nothing in scope.

## Links

Lead `../backlog/B-248-http1-drops-the-error-details.md` closed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` -- `applied: [..., 681]`.
