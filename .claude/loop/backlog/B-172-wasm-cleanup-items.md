---
status: closed (round 698) — round 689 and a cleanup commit by owner decision
round: 698
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift, packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt, packages/transport/rpc_dart_wasm/lib/src/rpc_wasm.dart]
probe: none — static read, nothing run
reason: "cost — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); a design or hygiene item with no failure to measure, decided by reading"
---

# B-172 — wasm: smaller native and Dart defects

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Racing checkSupport web views, unescaped script splicing, a retain cycle, an unguarded detach, unanswered replies after cancel, an empty channel name, a doc double start, a stale endpoint, a one-shot run, interop copies, an ignored HTTP status.

## The shape

1. `packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:276-279` — the recv loop never checks `r.ok`; the 499 that `stop()`
   answers (`:416-426`) is delivered to the guest as an empty frame. (The loop's
   silent give-up itself is B-38, closed by the owner, not re-filed.)
2. `packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:47-66` — concurrent `checkSupport` calls replace and deallocate each
   other's WKWebView.
3. `packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:286-287, 345-351` — glue spliced into an inline `<script>` without
   escaping `</script>`; `stripModuleSyntax` is an unanchored global replace while
   the leftover check is line-anchored.
4. `packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:567-568` — `userContentController.add(self, ...)` retains the runtime
   until `close()`; a runtime never closed after a reported death leaks a
   WKWebView and its process.
5. `packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift:312` — `?? ""` registers a handler on the empty channel name.
6. `packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:57` — `onDetachedFromEngine` closes runtimes without try; after
   `scope.cancel()` the per-message `launch` never runs its `finally`, so
   `reply.reply(null)` is never sent and Dart's `send()` hangs.
7. `packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:146-149` — error maps inconsistent (`runtimeId` missing); `messageCounter`
   atomic on a single thread; `var globalThis = this;` (`:175`); outbox budget
   arithmetic (`:309-323`) computes a constant.
8. `rpc_wasm.dart:31-35` — doc calls `endpoint.start()` inside `configure` and
   `_boot` calls it again; `_activeEndpoint` never cleared (`:40-43, 143`);
   `_initialized` makes `run` one-shot (`:63`); `toDart`/`toJS` read bytes through
   interop (`:188, 201`).
9. Drift facts for the owner's C-23/C-56 decisions: `onerror`/
   `onunhandledrejection` hooks exist on iOS only; a `performance` shim on Android
   only.

## Why it matters

Items 1, 2, 4 and 6 are behaviour; the rest hygiene.

## Witness a round would build

Item 6: detach the engine with a send in flight.

## Fix sketch

One commit per platform.

## Progress

- Item 2 FIXED in round 689: four concurrent iOS probes all answered "cannot
  run" against a single one's "can"; each probe now holds its own web view.
  `../rounds/689-concurrent-support-probes-agree.md`.
- Item 1, read in round 689: after `stop()` the guest gets one empty frame,
  then the next fetch fails and the loop ends. Not a spin.

## Outcome (cleanup, after round 698)

One cleanup commit, by owner decision, no round, beside round 689's item 2:

- 1: the iOS recv loop ends on a non-ok answer instead of handing the guest an
  empty frame.
- 3: the boot prefix and the glue are escaped (`</script` to `<\/script`)
  before they are spliced into the inline script. The strip's anchoring is
  left; the leftover check already refuses what it misses.
- 4: a reported death now releases the native runtime from Dart, once, so an
  iOS web view does not outlive a runtime the application never closes; the
  test that pinned "only close() releases" was updated.
- 6: detach closes each isolate and the sandbox under its own guard.
- 8: the `RpcWasm.run` example no longer starts the endpoint a second time,
  and the doc says why `run` is one-shot.

Left: 5 (`?? ""` is only reached when `self` is gone, where the whole call
chain short-circuits), 7 (an atomic counter, a `globalThis` alias and a
constant computed at run time are harmless), 9 (drift facts for the owner).
iOS guest suite 9 of 9, `analyze:native` PASS, `test:wasm` 51.

## Owner decision

2026-10-07: hygiene leads are **done as cleanup commits, without rounds**.
