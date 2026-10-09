---
status: closed (round 517)
round: 517
commit: 739756f5
paths: [packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart, packages/core/rpc_dart/lib/src/rpc/streams/base_processor.dart, packages/core/rpc_dart/lib/src/endpoint/ping.dart]
probe: P-154
reason: "closed — REFUTED on its stated consequence: the three builders produce the same header set, and unary DOES carry x-request-id with a null context. The code is still triplicated, so the refactor stands as a preference with no defect behind it; negative in checked/C-59"
---

# B-125 — request metadata is assembled in three places, and they have drifted

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`UnaryCaller.call`, `CallProcessor._sendInitialMetadata` and `ping()` each build the header map; with a null context CallProcessor adds `x-request-id` by constructing `RpcContext.empty()` just to read an id, the unary copy adds none.

## The shape

`packages/core/rpc_dart/lib/src/rpc/streams/unary/caller.dart:395-436`, `base_processor.dart:1233-1298`,
`caller_pipeline.dart:317-347`.

## Why it matters

The next header rule lands in one copy; already true for the request id.

## Witness a round would build

Diff the three outputs for the same context, including null.

## Fix sketch

One `buildRequestMetadata(service, method, context)`.

## Outcome (round 517) — REFUTED on the consequence

The header sets are the SAME, read off the wire:

```
                               with a context                  with NO context
unary  (UnaryCaller)           + grpc-timeout                  x-request-id present
server stream (CallProcessor)  + grpc-timeout                  x-request-id present
ping()                         + x-rpc-ping-timestamp          x-request-id present
```

**The null-context row is the one this lead names, and unary carries `x-request-id`
there** — and `x-trace-id` with it. The two differences that exist are correct:
`grpc-timeout` only when a context carried a deadline, and `x-rpc-ping-timestamp`
only on ping, which is a different operation with its own bound.

Full table in `checked/C-59`.

## What still stands, and why it is not a round's job

**The code IS triplicated.** Three sites assemble headers, and the risk named here —
"the next header rule lands in one copy" — is a real maintainability argument.

What is refuted is that the drift has ALREADY happened, which was the evidence
offered for acting now. So `buildRequestMetadata(service, method, context)` is a
refactor with no defect behind it: worth doing on its own merits, not because
something is broken.

## Owner decision

—
