---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/endpoint/responder_registry.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
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

## Owner decision

—
