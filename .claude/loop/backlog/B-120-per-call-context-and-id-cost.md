---
status: open
round: — (external audit, 2026-09-28; not a round)
commit: 8253fe8a
paths: [packages/core/rpc_dart/lib/src/contracts/context.dart, packages/core/rpc_dart/lib/src/endpoint/caller_pipeline.dart, packages/core/rpc_dart/lib/src/core/metadata.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-120 — each call copies both context maps five to seven times and draws 12 bytes of OS entropy

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Every `with*` rebuilds `_headers` and `_values` via `Map.from`, `withAdditionalHeaders` re-runs the header regex over all headers, the pipeline chains 5-7 of them per call; `requestId` is three `Random.secure().nextInt` calls, the server mints a trace id too; `forClientRequest` runs two regexes per call.

## The shape

`packages/core/rpc_dart/lib/src/contracts/context.dart` constructor (`Map.from(headers)`, `Map.from(values)`),
`_uniqueToken`, `_sanitizeHeaders`; `caller_pipeline.dart:134-178`;
`metadata.dart:117-127, 471-484`.

## Why it matters

Allocation and syscalls on the per-call path; visible on in-memory and isolate
where the transport itself is cheap.

## Witness a round would build

Unary calls/s over the in-memory pair with a profiler; share of time in
`RpcContext._` and `_uniqueToken`.

## Fix sketch

Persistent/structural sharing for headers and values, validate once, a
non-cryptographic id generator seeded once (ids are correlation, not secrets).

## Owner decision

—
