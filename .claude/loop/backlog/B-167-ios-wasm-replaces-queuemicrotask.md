---
status: closed (round 686)
round: 686
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
---

# B-167 — iOS wasm: the boot script replaces WKWebView's native queueMicrotask

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

`function queueMicrotask(fn) { _microtaskQueue.push(fn); }` is flushed only on a timer tick, a recv or boot; Dart continuations resumed from native promise callbacks (`JSPromise.toDart`) that schedule through it wait for the next tick or frame — indefinitely when idle; the polyfill is needed in Android's bare sandbox, not in a WebView (unverified against the generated .mjs).

## The shape

`packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:192`.

## Why it matters

Stalls in guests that use browser APIs returning promises.

## Witness a round would build

Guest awaiting a `Future.delayed(Duration.zero)` after a `fetch` with no other
traffic; time to resume.

## Fix sketch

Keep the native `queueMicrotask` on iOS.

## Outcome (round 686)

FIXED, on both platforms -- Android had the same queue. A guest awaiting
`Promise.resolve()` 100 times timed out at 10 s on both; now 1 ms. iOS keeps
WebKit's `queueMicrotask`; Android's goes through a promise job.
`../rounds/686-the-engine-runs-the-microtasks.md`.

## Owner decision

—
