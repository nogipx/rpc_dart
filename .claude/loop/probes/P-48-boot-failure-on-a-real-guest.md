---
file: packages/transport/rpc_dart_wasm/example/wasm_guest/main.dart
round: 356
commit: 6c769c66
paths: [packages/transport/rpc_dart_wasm/lib/src/wasm/**, packages/transport/rpc_dart_wasm/example/**]
status: valid
---

# P-48 — what a failed boot hands back, inside a real dart2wasm guest

The guest's `main()` calls `RpcWasm.run` twice: once with a `configure` that
throws, recording what it caught in `_bootFailureSeen`, then for real. The
integration test reads that string back over RPC (`Echo/BootFailure`). Run with
`melos run test:wasm:device` against a booted simulator or emulator.

**This is the only bench that can see this code at all.** `rpc_wasm.dart` is
`dart:js_interop`, so it never executes on the VM — `melos run test:wasm` is
`flutter test` and cannot reach a single line of it, and `test:web` does not
include this package.

## Measures

Two things, both on the library's side: the exception type and message
`RpcWasm.run` hands its caller when the boot fails, and how many of the suite's
other guest tests still pass — which is what says whether the failed boot left
anything behind.

## Control

The suite's other guest tests are the control: they exercise the SECOND,
successful boot, over the same JS globals the first one touched. An arm where
the witness passes and they fail is a different defect from one where both fail.

```
arm                             witness                          other guest tests
fixed                           StateError: configure exploded    9 of 9 pass
rethrow removed                 LateError: LateInitializationError:
                                Local 'result' has not been
                                initialized.                      9 of 9 pass
bridge cleanup removed          (never reached)                   0 of 9 pass
```

The two ablations fail DIFFERENTLY, which is what makes them two halves rather
than one: dropping the rethrow corrupts the ERROR, dropping the cleanup kills
the host-to-guest pipe for everything that follows.
