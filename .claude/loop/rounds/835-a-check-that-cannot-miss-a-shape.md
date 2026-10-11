---
round: 835
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness test is the measurement; round 834's probe is the before
commit: yes
severity: S2
release: changelog
---

# Round 835 — a check that cannot miss a shape

## Target

B-291, decided by the owner 2026-10-11 in two steps. First: a `beforeCall`
hook on `IRpcInterceptor`. Implemented, the gate failed: `rpc_dart_opentelemetry`
declares `OtelRpcInterceptorBase implements IRpcInterceptor`, so a new
member on that class is a compile error there, and in every published otel
version resolved against the new core. Asked again with that measured; the
owner chose a separate opt-in interface.

## Hypothesis

An interceptor's check can be made to run for every call shape without a
change that breaks a class implementing `IRpcInterceptor`.

## Before

Round 834's probe (`r834_auth_interceptor_shapes.dart`), a check in
`interceptUnary` only: no token gets unary 16, server-stream, client-stream
and bidi served.

The `beforeCall` attempt, `melos run analyze`: `error - lib/src/interceptor/otel_rpc_client_interceptor.dart:28:7
- Missing concrete implementation of 'abstract class IRpcInterceptor.beforeCall'`
(and `otel_rpc_interceptor.dart:44:7`); `test:unit`: five otel test files
fail to load.

## Mechanism

`IRpcInterceptor` is an abstract class whose methods have bodies; Dart lets
a class `implements` it, and such a class must then define every member,
new ones included.

## Fix

- `abstract interface class IRpcCallCheck { FutureOr<void> check(call); }`
  in `middleware.dart`, exported with it.
- `RpcEndpointBase`'s four interceptor chains run `check` before an
  interceptor's own method when it `is IRpcCallCheck`, outermost first; a
  synchronous check is not awaited (`_beforeCall` returns null), so it costs
  a call no turn.
- `IRpcInterceptor`'s dartdoc and the skill point a check at it; the
  skill's `RequireTokenInterceptor` is `extends IRpcInterceptor implements
  IRpcCallCheck` with one `check`.

## After

Witness `packages/core/rpc_dart/test/endpoint/a_token_check_covers_every_call_shape_test.dart`
(+17), VM and node: for each of the four shapes, a call without a token is
refused UNAUTHENTICATED and one with a token served; an asynchronous check
refuses each shape; a check on the CALLER endpoint refuses each shape; two
interceptors run `a.check, a.unary, b.check, b.unary`.

## Canary

`_beforeCall` returning null at once, in place: 13 of the 17 fail (every
refusal and the order; the four token-served GUARDs pass), first message
`Expected: <16> Actual: RpcString:<secret>`. Restored.

## The verdict questions

1. Only whether the check runs differs.
2. Yes: refused against served.
3. At the caller: the status or the served value.
4. Four shapes, two endpoints, sync and async.
5. Quoted.
6. One mechanism, one canary; the witness covers both endpoints.
7. From the numbers.
8. The `beforeCall` design was dropped on a measurement (the otel compile
   error), not on a reading.
9. none.
10. Siblings below.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`melos run analyze`, `test:unit`, `check:skills` green; the witness on node.

## Siblings

- caller and responder endpoints: both, through `RpcEndpointBase` (the
  witness covers both)
- transports: n/a, the chain is core's
- `rpc_dart_opentelemetry`, `rpc_dart_framework` interceptors: unchanged,
  they keep compiling

## Not fixed

none.

CHANGELOG line (minor): "rpc_dart: `IRpcCallCheck` — an interceptor that
also implements it has `check(call)` run before its method for every call
shape, so an authentication or quota check cannot miss the streaming shapes.
The skill's token-check example uses it."

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md`. Lead
`../backlog/B-291-a-check-interceptor-covers-only-the-shapes-it-overrides.md`
(closed). Round `834-the-documented-token-check-served-streams-unauthenticated.md`.
