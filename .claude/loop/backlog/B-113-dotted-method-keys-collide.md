---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/core/metadata.dart, packages/core/rpc_dart/lib/src/endpoint/responder_pipeline.dart, packages/core/rpc_dart/lib/src/endpoint/responder_registry.dart]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
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

## Owner decision

—
