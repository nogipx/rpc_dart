---
round: 744
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-13
bench: P-248 — new
commit: yes
release: changelog
---

# Round 744 — every unawaited site, from the analyzer

## Target

RPC-13 has been applied twenty times, every time from grep. The workspace
analyzer is now reachable through dart-runner's `find_references`, which lists
every reference to `unawaited` resolved by type rather than by text. The
target is the whole list: is there a dropped future, in library code, that can
complete with an error?

## Hypothesis

At least one `unawaited(...)` in `lib/` wraps a future that can fail with no
`catchError` and no `try` inside it.

## Before

`find_references(unawaited, scope lib)` returned 117 sites in the workspace
(plus 65 inside pub-cache dependencies, because `scope: lib` matches their
`/lib/` too). grep over the same `lib/` trees counts 128 lines. The 11 missing
are every site in `rpc_dart_wasm`: a Flutter package resolves `dart:async`
from `sky_engine`, so its `unawaited` is a different element from the Dart
SDK's. They were read by hand.

Sorted by what the dropped future can do (categories, not counted per row):

```
  StreamController.close(): its done never fails
  .catchError, or a try inside the closure
  cancel() of a subscription to an internal controller with no onCancel
  http2 terminate(): Future.wait(...).catchError inside
  dart:io WebSocket.close(): I/O errors complete it normally
  closeRuntime with no catchError              rpc_flutter_wasm_bridge.dart:235
```

The last one is the native plugin answering `loadRuntime` with a runtime id it
was not asked for. `load()` releases that runtime without awaiting it and
throws UNAVAILABLE. Witness, `closeRuntime` throwing:

```
  the foreign runtime is released                    passed  (control)
  WITNESS a failing release does not escape ...      FAILED
    PlatformException(gone, no such runtime, null, null)
    package:rpc_dart_wasm/src/rpc_flutter_wasm_bridge.dart 236:18  RpcFlutterWasmBridge.load
```

## Mechanism

The sibling `_releaseNative()` (line 101) wraps the same `closeRuntime` call
in `.catchError`. The foreign-id branch, added later, does not.

## Fix

`.catchError((Object _) {})` on the foreign-id release, as `_releaseNative`
has it.

## After

```
  the foreign runtime is released                    passed
  WITNESS a failing release does not escape ...      passed
```

## Canary

The Before run is the canary: the same test against the code without the
`catchError` fails with the uncaught `PlatformException` above.

## The verdict questions

1. Yes: the branch is reachable only through a misbehaving plugin, so it is
   driven through the mocked channel.
2. Yes: the control passes on the same rig.
3. In flutter_test's uncaught-error report.
4. n/a.
5. Quoted.
6. One mechanism, one observable.
7. Not a trade.
8. None.
A1. A plugin that ignores the requested id, and then fails to close.
A2. An uncaught error. In a Flutter app it reaches `PlatformDispatcher.onError`;
it does not end the isolate.
L1. n/a.

## Gate

`test:wasm` (53, two new), `analyze`, `format:check`, `license:check`. No core
change, so `test:unit` was not rerun.

## Not fixed

Severity is low: the branch needs a plugin that breaks its own contract, and
Flutter reports rather than dies. Fixed because the sibling already shows the
form and the cost was one line.

## Links

Lens `../lenses/RPC-13-unhandled-async-error.md` — `applied: [..., 744]`.
New bench `../probes/P-248-a-foreign-runtime-release.md`.
