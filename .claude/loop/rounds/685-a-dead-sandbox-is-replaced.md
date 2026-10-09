---
round: 685
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — a new gated kill probe (`example/integration_test/reload_after_sandbox_death_test.dart`) on round 684's rooted AVD
commit: yes
release: changelog
severity: S2
---

# Round 685 — a dead sandbox is replaced

## Target

B-166: the Android plugin caches its `JavaScriptSandbox` for its whole
lifetime, so after the sandbox process dies every later `loadRuntime` fails;
and a failed bind is cached the same way.

## Hypothesis

The lead's: `ensureSandbox` returns the cached sandbox without asking whether it
is alive, and caches the bind future even when it fails.

## Before

The new probe on `rpc_root_33` (round 684's rooted AVD): load a runtime, kill
the sandbox process, load another:

```
PROBE first runtime closed: true
PROBE second runtime: LOAD FAILED RpcStatusException(14): Failed to load WASM runtime: sandbox dead: sandbox was dead before call to createIsolate
```

## Mechanism

As hypothesised, with one detail the first fix attempt got wrong:
`createIsolate` on a dead sandbox does NOT throw. It returns an isolate, and
the `SandboxDeadException` comes from the first evaluation, the boot script
(logcat: `RpcDartWasmPlugin.loadRuntime`, inside `withTimeoutOrNull`). A catch
around `createIsolate` therefore never fires; that attempt read exactly as
Before.

## Fix

`RpcDartWasmPlugin.kt`:

- The isolate's termination callback (round 684), on `STATUS_SANDBOX_DEAD`,
  calls `dropDeadSandbox(sb)`: it clears the cached sandbox and bind future and
  closes the dead one, but only if the cache still holds THAT sandbox -- every
  isolate of a dead sandbox reports, and a late one must not drop a sandbox
  bound since.
- `ensureSandbox` clears the bind future when the bind fails, so the next call
  tries again instead of rethrowing the old failure.

## After

```
PROBE first runtime closed: true
PROBE second runtime: echo:b
```

## Canary

The first fix attempt is the canary for the sandbox half: the same tree with
the failed-bind reset, but without the drop on death (a catch around
`createIsolate` instead), read exactly as Before. The failed-bind half is not
witnessed: a bind that fails transiently could not be produced.

## The verdict questions

1. Partly: the death half has a canary, the failed-bind half has none.
2. Yes: the scenario the lead named, a kill and a reload.
3. Yes: whether a new runtime answers a call.
4. Not zero-valued.
5. Yes, quoted.
6. Two halves; one measured.
7. Not a policy question.
8. None.

## Gate

`analyze:native` (Swift and Kotlin PASS), `test:wasm:device` on the Android
emulator (27 passed, 4 skipped: the two kill probes are gated), the two example
test files analysed clean.

## Not fixed

The failed-bind reset is by reading only. `checkSupport` still starts the
sandbox service just to probe (the lead's last clause); a cost, not a defect.

## Links

Lead `../backlog/B-166-the-android-wasm-sandbox-is-cached-forever.md` closed.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 685]`.
