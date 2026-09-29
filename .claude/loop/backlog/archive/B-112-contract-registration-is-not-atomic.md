---
status: closed (round 503)
round: 503
commit: e82f586b
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_registry.dart, packages/core/rpc_dart/lib/src/contracts/contract.dart]
probe: P-141
reason: "closed — CONFIRMED and fixed: the contract was inserted before setup() and before the key checks, so both failure routes left it registered (one with a live, serving method) and the only recovery was refused with 'already registered'. setup() and every key check now run before a single commit"
---

# B-112 — registerContract inserts the contract before validating its methods

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`_contracts[serviceName] = contract` happens before the method loop, which throws on a duplicate method key; the endpoint is left with the contract and some of its methods registered.

## The shape

`packages/core/rpc_dart/lib/src/endpoint/responder_registry.dart` `registerContract`: insert, `setup()`,
then for each method `if (_methods.containsKey(methodKey)) throw ...`. Also
`_log = logger` is reassigned on every call.

## Why it matters

A caller that catches the error and retries registration gets "already
registered"; half a contract serves requests.

## Witness a round would build

Register A with methods x, y; register B whose second method collides. Inspect
`registeredContracts`/`registeredMethodBindings`.

## Fix sketch

Validate all keys first, then insert.

## Outcome (round 503)

**CONFIRMED and fixed**, with one thing the lead did not say and one it got
slightly wrong.

The thing it did not say: **the endpoint cannot be repaired.** The lead notes the
retry gets "already registered"; what follows is that a registration failure is
terminal for that service name, because catch-fix-retry is the only recovery a
caller has and it is exactly what is refused.

The thing it got slightly wrong: the duplicate-method route is not reachable on its
own. `contract.methods` is a Map and the contract's `_rejectDuplicate` spans both
its method maps, so one contract cannot collide with itself. A cross-contract key
collision needs two service/method pairs that produce the same `'$service.$method'`
string, which requires the dotted-key ambiguity of **B-113**. So that route depends
on the next lead.

The route that needs nothing else to be wrong is **`setup()` throwing**, one line
after the insert — a contract author who copy-pastes a method name. Measured:

```
                              before                          after
setup() throws         contracts [Svc]  methods []            contracts []  methods []
                       retry: already registered              retry: succeeds
2nd method collides    contracts [a, a.b]                     contracts [a]
                       methods [a.b.c, a.b.ok]                methods [a.b.c]
                       a.b/ok answers 'ok'                    a.b/ok -> UNIMPLEMENTED
                       retry: already registered              retry: succeeds
```

Fixed as the sketch says: `setup()` and every key check run first, bindings are
built into a local map, and one commit applies contract and methods together.
`pending` is also checked against itself, which is unreachable today but costs a
lookup and removes the dependency on a guarantee living in another class.

## Owner decision

—
