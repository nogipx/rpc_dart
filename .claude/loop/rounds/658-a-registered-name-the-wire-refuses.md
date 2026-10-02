---
round: 658
verdict: FIXED
packages: [rpc_dart]
lens: RPC-25
bench: none — the witness test is the measurement; reviewer probe peer_registration_names.dart
budget: probes 1/5, canaries 1/5
commit: yes
release: changelog
---

# Round 658 — a registered name the wire refuses

## Target

A peer and middleware review (this round's agent) of
`RpcResponderRegistry.registerContract`.

## Hypothesis

A name registration accepts is one a caller can reach, and reaches only its
own handler.

## Before

```
service S registers method `a.b`        key S.a.b
call /S.a/b                             served by S/a.b -- another service's handler
S{a.b} then S.a{b}                      REFUSED: Method S.a.b is already registered
method `x/y`                            registered; every call: ArgumentError Invalid name
```

## Control

S registers `ab`: the same call gets `RpcStatusException(12): Method S.a.b is
not registered`.

## Mechanism

RPC-25: one grammar, three enforcers, one missing. The binding key
`'$service.$method'` is injective only because a method name has no dot
(`kMethodTokenPattern`); the caller's metadata and the responder's path parser
both enforce that, registration did not. The wrong-method dispatch B-113
closed from the wire side was open again from the registration side, silently.

## After

Registration checks the service name against `kServiceTokenPattern` and each
method against `kMethodTokenPattern`, and refuses INTERNAL like its other
registration errors. A dotted service name (`myapp.v1.S`) still registers and
is served.

## Canary

Both checks disabled: the three refusal arms pass registration.

## Gate

Rounds 658-659 together; recorded in round 659.

## Not fixed

Behaviour change for a contract registering such a name: it was unreachable or
misrouted before, and now fails at registration. Round 503's
`a_failed_registration_leaves_nothing_behind_test` used exactly that
collision to reach its second failure route; it now reaches it through a
refused name.

## Links

Lens `../lenses/RPC-25-the-same-abstraction-four-times.md` — `applied: [..., 658]`.
Test `packages/core/rpc_dart/test/endpoint/a_name_the_wire_refuses_cannot_be_registered_test.dart`.
