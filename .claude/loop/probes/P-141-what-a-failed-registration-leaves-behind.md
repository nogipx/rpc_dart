---
file: packages/core/rpc_dart/.dart_tool/probe/b112_partial_registration.dart
round: 503
commit: e82f586b
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_registry.dart, packages/core/rpc_dart/lib/src/contracts/contract.dart]
status: valid
---

# P-141 — what does a failed registration leave behind?

## Why it exists

`registerContract` has several statements that can throw and one that mutates. The
question is not whether it throws correctly — it does — but what the registry looks
like AFTERWARDS, and whether the caller can do anything about it.

So the arms vary WHERE the failure lands relative to the insert, and each prints
three things: what threw, the state the failure left, and whether the one recovery
a caller has — catch, fix the contract, register again — works.

The third is the one that turns an untidy internal state into a defect. A partial
registration that could be cleaned up is a wart; one that refuses the only
correction available is a dead endpoint.

## The harness

Two failure routes, because they are reachable independently.

1. **`setup()` throws.** A contract whose own `setup()` lists a method name twice;
   the contract's `_rejectDuplicate` refuses it. This needs nothing else in the
   library to be wrong, which is what makes it the primary arm.
2. **The method loop throws partway.** Service `a` with a dotted method `b.c`, then
   service `a.b` with methods `ok` and `c` — both produce the key `a.b.c`. Map
   insertion order is iteration order, so `ok` is processed first and the throw
   lands with one method already handled. Reaching this route requires the dotted-
   key ambiguity B-113 is about, which is itself a fact about B-112.

A fourth block drives real calls into the half-registered service, because the
state only matters if requests reach it.

## The numbers (round 503)

Before:

```
setup() throws
  state AFTER fail : contracts [Svc]  methods []
  retry threw      : Contract for service Svc is already registered
method loop throws on its 2nd method
  state AFTER fail : contracts [a, a.b]  methods [a.b.c, a.b.ok]
  retry threw      : Contract for service a.b is already registered
  calling a.b/ok -> ok
  calling a.b/c  -> from a/b.c
CONTROL a clean contract, registered twice
  state AFTER      : contracts [Svc]  methods [Svc.recovered]
  retry threw      : Contract for service Svc is already registered  <- must be refused
```

After:

```
setup() throws
  state AFTER fail : contracts []  methods []
  retry threw      : nothing
  state after retry: contracts [Svc]  methods [Svc.recovered]
method loop throws on its 2nd method
  state AFTER fail : contracts [a]  methods [a.b.c]
  retry threw      : nothing
  state after retry: contracts [a, a.b]  methods [a.b.c, a.b.recovered]
  calling a.b/ok -> RpcStatusException(12): Method a.b.ok is not registered
  calling a.b/c  -> from a/b.c
CONTROL a clean contract, registered twice
  retry threw      : Contract for service Svc is already registered  <- must be refused
```

## Measures

The registry's own `registeredContracts` and `registeredMethodBindings` key sets,
snapshotted immediately after the failure and again after the recovery attempt,
plus the answer a real call gets. Not counts — the actual keys, because "one
method" and "which method" are different facts and only the second distinguishes
the failed contract's method from the pre-existing one.

## Control

**A clean contract registered twice, which must be refused.** Every arm ends in
"already registered", so without this arm that message reads as the defect. It is
not: refusing a genuine duplicate is correct, and the control says so. What the
arms show is that the same message appears when the first registration FAILED —
the state, not the second error, is the finding.

The recovery contract also declares a deliberately distinct method name
(`recovered`). An earlier version reused `ok`, which the failing contract also
declares, so the after-state was identical to the before-state and the arm proved
nothing. The key set has to name whose registration is live.

## What it establishes, and what it does not

Establishes: the contract was inserted before anything that can throw, so both
failure routes left it registered — with no methods in the first case, with some of
its methods live and serving in the second — and the only recovery a caller has was
refused. After the fix both routes leave the registry byte-identical to its prior
state and the recovery succeeds.

Does NOT fix or excuse the dotted-key ambiguity. `a.b/c` still dispatches to
service `a`'s method `b.c` in the after-table, which is B-113 and untouched here;
this round only stops a failed registration from leaving debris. Nor does it cover
`unregisterContract`, or a `setup()` that throws asynchronously — `setup()` is
synchronous, so that case does not exist.
