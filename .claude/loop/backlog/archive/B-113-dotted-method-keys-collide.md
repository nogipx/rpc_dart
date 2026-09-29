---
status: closed (round 504)
round: 504
commit: 54382ce7
paths: [packages/core/rpc_dart/lib/src/core/metadata.dart, packages/core/rpc_dart/lib/src/core/security_policy.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart]
probe: P-142
reason: "closed — CONFIRMED and fixed, and the lead's own likelihood estimate was wrong: nothing unusual has to be registered, only the request is crafted. One token pattern served both halves of the path while the key format needs exactly one half to admit dots; split into kServiceTokenPattern and kMethodTokenPattern"
---

# B-113 — `/a.b/c` and `/a/b.c` resolve to the same method key

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

The path is parsed into (service, method) and joined back as `'$service.$method'`; `kMethodTokenPattern` admits dots in BOTH parts, so two distinct paths share a key and a request can dispatch to another service's method.

## The shape

`packages/core/rpc_dart/lib/src/core/metadata.dart:21` `RegExp(r'^[A-Za-z0-9_.-]+$')` for service AND
method; `responder_pipeline.dart:942` `'$serviceName.$methodName'`;
`rpcMethodPathFromKey` splits on the last dot.

## Why it matters

Low likelihood (dotted method names are unusual) but the grammar allows them and
the routing silently merges them.

## Witness a round would build

Register service `a.b` method `c`; call `/a/b.c`. Expected: dispatched to `a.b/c`.

## Fix sketch

Key by the (service, method) record, or forbid dots in method names in the
grammar.

## Outcome (round 504)

**CONFIRMED and fixed. The lead's "low likelihood" is wrong**, and correcting it is
the useful part. The lead says the defect needs a dotted METHOD name registered. It
does not — registered `service "a.b", methods "c" and "secret"`, which is an
ordinary package-qualified gRPC service with ordinary methods, is enough. Only the
REQUEST is crafted:

```
                  before                 after
/a.b/c            reached a.b/c          reached a.b/c   <- control
/a/b.c            reached a.b/c          status 3
/a/b.secret       reached a.b/secret     status 3
/a/c              status 12              status 12       <- control
```

Fixed by the sketch's second option: `kServiceTokenPattern` keeps the dot,
`kMethodTokenPattern` loses it. `rpcMethodPathFromKey`'s doc had always STATED this
invariant — "a service name may contain them, a method name may not" — so the fix
makes the code enforce what the comment already promised. Not public API; the whole
repo contained one dotted method name, in a test.

Keying by a `(service, method)` record (the sketch's first option) was not taken:
`registeredMethodBindings` is a public getter whose keys are that string, so
changing the key format is a breaking API change for a strictly smaller benefit.

**Checked and refuted: there is no in-process authorisation bypass.** A responder
interceptor denying service `a.b` by name denied BOTH paths, and saw `a.b/secret`
for both — the binding is resolved before the middleware context is built, so an
interceptor never sees the caller's split.

## Split out to B-201 — not closed by this fix

**Path-string filtering upstream of the responder.** A reverse-proxy rule, gateway
ACL or access-log filter matching `/a.b/` did not cover `/a/b.`, because both
reached the same method. The responder now refuses the second form, which closes it
going forward and does nothing for rules already trusted or logs already written.

**`rpc_dart_http`'s responder inherits the fix by construction** (it calls
`policy.isValidMethodPath`) but was not run in round 504.

## Owner decision

—
