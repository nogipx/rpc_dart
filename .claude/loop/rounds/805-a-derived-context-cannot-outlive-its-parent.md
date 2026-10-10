---
round: 805
verdict: FIXED
packages: [rpc_dart]
lens: RPC-14
bench: P-276 — reused
commit: yes
severity: S2
release: breaking
---

# Round 805 — a derived context cannot outlive its parent

## Target

B-273, decided by the owner 2026-10-10 (options 1 and 3):
`createChildWith(timeout:)` and `RpcContextBuilder.inheritFrom(...)
.withTimeout` keep the earlier deadline; a forwarding helper keeps deadline,
token and trace and drops credentials; `sanitize` stays a logging helper and
says so; `RpcContext.withDeadline` / `withTimeout` keep replacing. Rank 1 of
the decided leads after rounds 803 and 804.

The class: every derivation path in `context.dart` — `createChild`
(inherits, no timeout: already kept the deadline), `createChildWith`,
`inheritFrom(...).withDeadline` / `.withTimeout`, and `sanitize`. All four
go through `RpcContextBuilder`, so the bound sits there, on a builder that
`inheritFrom` made.

## Hypothesis

A child built for a downstream call takes the timeout it is given as its
whole deadline, so with less time left the downstream is told more.

## Before

P-276 at 7afd93ba (client 200 ms -> A -> B, B waits 3 s or its token):

```
  variant               B told     B ran     B ended
  createChild           176 ms     186 ms    cancelled
  createChildWith(2s)   1999 ms    198 ms    cancelled
  withTimeout(2s)       1999 ms    201 ms    cancelled   (control: replaces)
  sanitize              none       3002 ms   finished
```

## Mechanism

`RpcContextBuilder.withTimeout` called `RpcContext.withTimeout`, which
replaces the deadline; `inheritFrom` is a builder like any other, so a
derived child replaced its parent's deadline. B stopped at ~200 ms only
because the token is inherited; its own `remainingTime` read 2 s, and a
further `createChild()` would tell the next hop 2 s. `sanitize` drops the
deadline and the token with the credentials, and it was the documented way
to strip credentials before a downstream call.

## Fix

A builder from `inheritFrom` is marked derived; its `withDeadline` keeps the
current deadline when that is earlier, and `withTimeout` is `withDeadline` of
the clock plus the timeout. `createChildWith` inherits that. New
`RpcContext.forward({headers, timeout})`: `createChildWith` minus
`authorization`, `x-api-key` and `cookie` (one list, shared with
`sanitize`). `sanitize`'s doc says it is for logging and points to
`forward`. The shipped skill's context reference: the derivation rule,
`forward`, the forwarding example rewritten to `forward`, and `sanitize`
described as logging-only.

## After

```
  variant               B told     B ran     B ended
  createChild           175 ms     185 ms    cancelled
  createChildWith(2s)   198 ms     202 ms    cancelled
  withTimeout(2s)       1999 ms    206 ms    cancelled   (unchanged, decided)
  sanitize              none       3001 ms   finished    (unchanged, documented)
  forward               198 ms     202 ms    cancelled
  forward(2s)           196 ms     199 ms    cancelled
```

Witness `test/contracts/a_derived_context_keeps_the_earlier_deadline_test.dart`
(11 tests, a fixed clock): three WITNESS cases, two GUARD cases that a
shorter or a first deadline still applies, two GUARD cases that an explicit
`RpcContext.withTimeout` and `RpcContextBuilder.from(...).withTimeout` still
replace, and four `forward()` cases.

## Canary

1. The derived check off: the three WITNESS cases and `forward() cannot
   extend the deadline either` fail, `Expected: DateTime:<2026-10-10
   12:00:00.200Z> Actual: DateTime:<2026-10-10 12:00:02.000Z>`; the GUARDs
   pass.
2. `forward`'s credential filter off: `forward() drops the credentials`
   fails, `Expected: null Actual: 'Bearer secret'`.

Restored: 11 passed.

## The verdict questions

1. The control variant `withTimeout(2s)` differs only in being an explicit
   replacement, which the owner kept; it reads 1999 ms before and after.
2. Yes: 1999 ms against 198 ms for the same parent.
3. B's own `remainingTime` at handler start, read by the downstream.
4. n/a.
5. Quoted.
6. Two halves, two canaries.
7. From the numbers.
8. No target dismissed.
9. none.
10. No sibling group holds `context.dart`.
A1. n/a. A2. n/a. L1. n/a.

## Gate

`melos run analyze`, `format:check`, `license:check`, `check:skills`,
`test:web` (15 suites): green. `test:unit`: the FIRST run exited non-zero
and its failure text was cut from the captured output, so which test failed
is not known; a second run was green in all 16 suites (core +2175 ~1). Not
called a flake: nothing was varied to show it is one. A local run of the
isolate package from the repository root also failed
`a_failed_spawn_lets_the_process_exit_test`, which needs its package
directory; from there it passes.

## Siblings

No sibling group holds `packages/core/rpc_dart/lib/src/contracts/context.dart`.

## Not fixed

- `RpcContext.withDeadline` / `withTimeout` on a context still replace, as
  decided; a handler that calls them on its incoming context can still
  extend what it forwards.
- `forward` drops three named headers; an API key under a custom header name
  still travels. The skill says so.
- The lost text of the first `test:unit` failure (Gate).

CHANGELOG line (breaking): "A context derived with `createChildWith(timeout:)`
or `RpcContextBuilder.inheritFrom(...).withDeadline/withTimeout` now keeps
the parent's deadline when it is earlier: a child can shorten a deadline,
never extend it. Code that extended a child's deadline on purpose must set
it with `RpcContext.withDeadline`/`withTimeout`. New `RpcContext.forward()`
for a downstream call keeps deadline, cancellation and trace and drops
`authorization`, `x-api-key` and `cookie`; `RpcContext.sanitize` is for
logging."

## Links

Lens `../lenses/RPC-14-timeout-abandons-work.md`. Bench
`../probes/P-276-a-forwarded-context-can-outlive-its-parent.md`. Lead
`../backlog/B-273-the-documented-forwarding-paths-extend-or-drop-the-deadline.md`,
closed.
