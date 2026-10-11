---
status: closed (round 835)
round: 834
commit: 5b62856f
release: changelog
paths: [packages/core/rpc_dart/lib/src/endpoint/middleware.dart]
probe: packages/core/rpc_dart/.dart_tool/probe/r834_auth_interceptor_shapes.dart
reason: "FIXED in round 835 as decided: IRpcCallCheck, an opt-in interface whose check runs for every shape. Previously: owner — a new public API (a hook that covers every call shape), or a change to IRpcInterceptor's defaults"
---

# B-291 — a check interceptor covers only the shapes it overrides

Round 834: `IRpcInterceptor`'s four methods each pass through by default, so
an interceptor written as a CHECK (authentication, authorization, a quota)
protects only the shapes it overrides. The shipped skill's own example
overrode `interceptUnary` alone, and a server built from it served
unauthenticated server-stream, client-stream and bidi calls (status 16 for
unary, `served secret` for the other three). Round 834 fixed the example and
the docs; the API still makes the unsafe version the short one.

Options for the owner:

1. A hook every shape runs first, e.g. `FutureOr<void> beforeCall(
   RpcMiddlewareContext call)` on `IRpcInterceptor` (pass-through default),
   so a check is one method and cannot miss a shape. Additive.
2. A separate `IRpcCallGuard` type registered with `addGuard`, run for every
   call before the interceptors. Additive, and makes the intent explicit.
3. Leave it to the docs (done in round 834).

## Owner decision

Owner, 2026-10-11: option 1, a `beforeCall` hook. Implemented in round 835,
it broke `rpc_dart_opentelemetry`, which `implements IRpcInterceptor` (and
would break its published versions against the new core). Asked again with
that: a separate opt-in interface, `IRpcCallCheck`.
