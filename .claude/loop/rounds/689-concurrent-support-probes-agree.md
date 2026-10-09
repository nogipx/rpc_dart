---
round: 689
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — a new device test, `example/integration_test/concurrent_check_support_test.dart`
commit: yes
release: changelog
severity: S2
---

# Round 689 — concurrent support probes agree

## Target

B-172 item 2: on iOS, concurrent `checkSupport` calls replace and release each
other's WKWebView.

## Hypothesis

`checkSupport` keeps its web view in one optional field. A second call
overwrites it, releasing the first view mid-evaluation, and each completion
sets the field to nil -- releasing whichever view is in it now.

## Before

One call, then four at once:

```
platform: ios      single: true  concurrent: [false, false, false, false]
platform: android  single: true  concurrent: [true, true, true, true]
```

Every concurrent iOS probe answered "cannot run", the last one included.

## Mechanism

As hypothesised: a released WKWebView fails its evaluation, and the failure
branch answers `hasWebAssembly: false`.

## Fix

`checkSupportWebViews`, a dictionary keyed by each view's `ObjectIdentifier`:
each probe holds its own view and removes only its own on completion.

## After

```
platform: ios  single: true  concurrent: [true, true, true, true]
```

## Canary

Before is the canary: the same test against the single slot. Android is the
control: no shared view, and it agreed before the change.

## The verdict questions

1. Yes: Before is the canary; Android the control.
2. Yes: the item named.
3. Yes: the answer an embedder branches on.
4. Not zero-valued.
5. Yes, quoted.
6. One cause.
7. Not a policy question.
8. None.

## Gate

`analyze:native` (Swift and Kotlin PASS); the new device test on both
platforms.

## Not fixed

B-172's other items; the lead stays open.

## Links

Lead `../backlog/B-172-wasm-cleanup-items.md` -- item 2 done, open.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 689]`.
