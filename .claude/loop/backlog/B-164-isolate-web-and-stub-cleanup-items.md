---
status: closed (round 698) — cleanup commit by owner decision
round: 698
commit: 8253fe8a
paths: [packages/transport/rpc_dart_isolate/lib/src/isolate_transport_web.dart, packages/transport/rpc_dart_isolate/lib/src/web_bridge.dart, packages/transport/rpc_dart_isolate/lib/src/worker_policy.dart, packages/transport/rpc_dart_isolate/lib/src/isolate_transport_stub.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-164 — isolate web/stub: hygiene

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

A broken doc reference, a required-but-ignored entrypoint, hand-written enum switches, a dead onDispose and a double close, lost repeated query parameters, a stub that throws synchronously and contradicts its doc.

## The shape

1. `isolate_transport_web.dart:60` — `[_policyQueryParam]` does not exist
   (`kWorkerPolicyQueryParam`).
2. `isolate_transport_web.dart:57` — `final _ = entrypoint;` required and ignored,
   `isolateId` unused, no hint to the user.
3. `web_bridge.dart:60-89` — two switches that are `.name` / `asNameMap()`.
4. `web_bridge.dart:252-261` — `onDispose` is never called by isolate_manager;
   `controller.close()` then `scope.close()` closes twice.
5. `worker_policy.dart:24-29` — `queryParameters` keeps one value per key;
   `queryParametersAll` needed.
6. `isolate_transport_stub.dart:10-29` — the doc says "not the web", the message
   says "targeting the web"; `spawn` is not async, so it throws synchronously and
   `.catchError` does not see it.

## Why it matters

Hygiene; item 5 and 6 are behaviour.

## Witness a round would build

None.

## Fix sketch

One cleanup commit.

## Outcome (cleanup, after round 698)

Done in one cleanup commit, by owner decision, no round: 1 (the doc names
`kWorkerPolicyQueryParam`), 2 (the comment says `entrypoint` and `isolateId`
are unused on the web and why), 3 (`type.name` and `asNameMap()`), 5
(`withWorkerPolicy` keeps every value of a repeated parameter; a VM test
added), 6 (the stub's `spawn` fails through its future, and its message no
longer says "web"). The web worker still compiles with dart2js.

Left: 4 (`onDispose` and the double close) -- changing teardown order on the
web without a browser witness is not hygiene.

## Owner decision

2026-10-07: hygiene leads are **done as cleanup commits, without rounds**.
