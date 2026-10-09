---
round: 503
verdict: FIXED
packages: [rpc_dart]
lens: RPC-21
bench: P-141 — new
commit: yes
severity: S2
---

# Round 503 — the throw that left half a service

## Target

`registerContract` on the responder registry — nineteenth in the audit's rank.

Lens RPC-21, *drive the lifecycle twice*. The fit is exact and it is why the defect
survived: every existing test drives `registerContract` ONCE, and once
successfully. The defect is only visible on the second drive, and only when the
first one failed — which is a variant the lens did not name, so this round adds it.

## Hypothesis

The contract is inserted before anything that can throw, so a failed registration
leaves the endpoint half-registered and the caller unable to correct it.

## Before

```
setup() throws
  state AFTER fail : contracts [Svc]  methods []
  retry threw      : Contract for service Svc is already registered
method loop throws on its 2nd method
  state AFTER fail : contracts [a, a.b]  methods [a.b.c, a.b.ok]
  retry threw      : Contract for service a.b is already registered
  calling a.b/ok -> ok
CONTROL a clean contract, registered twice
  retry threw      : Contract for service Svc is already registered  <- must be refused
```

Bench: `packages/core/rpc_dart/.dart_tool/probe/b112_partial_registration.dart`

**CONFIRMED, and worse than the lead claimed on the point that matters.** The lead
says "half a contract serves requests"; it does — `a.b/ok` answered `ok` from a
contract whose registration threw. What the lead does not say is that the endpoint
cannot be repaired: the only recovery a caller has is to catch, fix the contract and
register again, and that is refused with "already registered". A registration
failure is therefore terminal for that service name unless the caller knows to call
`unregisterContract` on a contract it believes was never registered.

The control carries the table. Every arm ends in "already registered", so without a
clean contract registered twice — which must also be refused — that message reads as
the defect. It is not; refusing a genuine duplicate is correct. The finding is the
state, not the second error.

## Mechanism

```dart
_contracts[serviceName] = contract;      // 1. mutate
if (contract.methods.isEmpty && ...) contract.setup();   // 2. can throw
for (final entry in contract.methods.entries) {
  if (_methods.containsKey(methodKey)) throw ...;        // 3. can throw
  _methods[methodKey] = ...;                             // and mutates as it goes
}
```

Three statements in the wrong order. The mutation is first, and both of the things
that can throw are after it — so every failure exit is a partial commit. Worse, the
method loop interleaves check and insert, so a throw on the Nth method leaves N-1
bindings live.

**Two failure routes reach it, and they are independent.** `setup()` throwing needs
nothing else in the library to be wrong: a contract author who copy-pastes a method
name gets `_rejectDuplicate` from inside `setup()`, which is called one line after
the insert. The method-loop route needs two services whose keys collide, which
requires the dotted-key ambiguity of B-113 — so that lead is not just adjacent to
this one, it is the only thing making this one's *second* route reachable.

## After

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
CONTROL a clean contract, registered twice
  retry threw      : Contract for service Svc is already registered  <- must be refused
```

`setup()` first, then every binding built and every key reserved into a local
`pending` map, then one commit — `_contracts[serviceName] = contract;
_methods.addAll(pending);`. Nothing above the commit touches a field, so a throw
leaves the registry as it was.

`pending` is checked against itself as well as against `_methods`: two of one
contract's own methods sharing a key must be refused rather than silently
collapsing into one binding. The contract's `_rejectDuplicate` makes that
unreachable today, which is exactly why the check belongs here — it costs a map
lookup and does not depend on a guarantee in another class.

The per-method `internal` logging moved below the commit and now iterates
`pending`, so it logs what was actually registered rather than what was about to
be. Both halves stay behind the `isInternal` guard.

Regression: `test/endpoint/a_failed_registration_leaves_nothing_behind_test.dart`,
4 WITNESS and 3 GUARD.

## Canary

Both halves of the ordering restored in place — `_contracts[serviceName] =
contract;` back above `setup()`, and `_methods[methodKey] = binding;` back inside
the reserve loop. All four WITNESS arms fail:

```
contracts empty          Expected: empty        Actual: ['Svc']
contracts == ['a']       Expected: ['a']        Actual: ['a', 'a.b']
recovery returnsNormally threw RpcStatusException: ... already registered
a.b/ok is UNIMPLEMENTED  emitted RpcString:<ok>
```

All three GUARDs stay green. The last line is the sharpest thing in the round: a
method belonging to a contract whose registration threw answered a request.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:unit --no-select` SUCCESS; `melos run format:check` SUCCESS with no
reformat needed; `melos run license:check` compliant.

## Not fixed

**B-113 is untouched and is next in rank.** `a.b/c` still dispatches to service
`a`'s method `b.c` in the after-table — the probe prints it, because suppressing it
would have hidden the fact that this round's second failure route depends on it.

**`_log = logger` is still reassigned on every `registerContract` and
`unregisterContract` call.** The lead names it. It is a mutable field standing in
for a constructor parameter, and the repo's own logging idiom is a non-nullable
`LogScope` resolved once in the initialiser list. Changing it means changing both
methods' signatures, which is a wider edit than this round's defect and has no
measured failure behind it.

**A `setup()` that throws is still the contract author's bug.** This round makes it
recoverable, not diagnosable — the thrown message names the duplicate method, which
is already the useful part.

## Links

Lens RPC-21 (extended: drive it twice where the FIRST attempt failed). Bench P-141
(new). B-113 is the lead this round's second failure route depends on, and it stays
open.
