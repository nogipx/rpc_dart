---
round: 700
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — `packages/core/rpc_dart/test/endpoint/peer_middleware_knows_the_direction_test.dart`
commit: yes
release: changelog
severity: S3
---

# Round 700 — peer middleware knows the direction

## Target

B-245, decided by the owner: on an `RpcPeerEndpoint` one middleware list runs
for the calls it makes and the calls it serves, and `RpcMiddlewareContext` was
identical both ways. Add a direction field.

## Hypothesis

Nothing to find: round 659 measured it (`A middleware invocations: 4`, request
out and in indistinguishable but for incidental signals). The work is the
field.

## Before

The witness -- peer A with one middleware; A calls B, then B calls A; record
what the middleware sees -- does not compile against the old API:
`The getter 'direction' isn't defined for the type 'RpcMiddlewareContext'`.

## Mechanism

As round 659 found.

## Fix

- `enum RpcCallDirection { outgoing, incoming }` and
  `RpcMiddlewareContext.direction`, optional in the constructor and in
  `copyWith`, so code building the context by hand keeps compiling; null only
  there.
- The four public `handle*` entry points take an optional `direction`; the
  caller pipeline passes `outgoing` (4 sites), the responder pipeline
  `incoming` (8). Interceptors receive the same context.
- The core skill's middleware paragraph names the field and when to use it.

## After

```
[RpcCallDirection.outgoing, RpcCallDirection.incoming]
```

## Canary

The context factory passing null: `Actual: [null, null]`. Restored: green.

## The verdict questions

1. Yes: one canary.
2. Yes: the scenario round 659 measured.
3. Yes: what the middleware receives.
4. Not zero-valued.
5. Yes, quoted.
6. One gap.
7. Yes; the owner chose the field over documenting.
8. None.

## Gate

`analyze`, `format:check`, `test:unit`, `check:skills` (clean on its second
run; the first reported FAILED and its output was not kept).

## Not fixed

Nothing in scope. Additive: a `feat` for the changelog.

## Links

Lead `../backlog/B-245-peer-middleware-cannot-tell-direction.md` closed.
Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` -- `applied: [..., 700]`.
