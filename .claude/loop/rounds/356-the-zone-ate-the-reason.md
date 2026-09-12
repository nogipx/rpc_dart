---
round: 356
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-13
bench: P-48 — new
commit: yes
---

# Round 356 — the zone ate the reason

## Target

The owner's 6.0.0 review list, P0 item 6, and the last of the P0s.

RPC-13's shape from the other side. That lens is about an async error with
nowhere to go; this is a guarded zone catching an error that was never async and
had somewhere to go — the caller. `D2` in the measurement checklist already
states the rule: *a guarded zone catches only its own side's errors — check
whose code threw*.

**Scope counted before the fix.** `runZonedGuarded` appears exactly once in the
workspace's `lib/` — `rpc_wasm.dart:76`. Every other zone use is in tests and
probes, where swallowing is the point. So the class has one member.

## Hypothesis

`RpcWasm.run` assigns its result inside a `runZonedGuarded` body and returns it
after. A synchronous throw out of a zone body goes to the zone's handler, not to
the caller — so `runZonedGuarded` returns normally, the `late final` is never
assigned, and `return result` fails on its own uninitialised variable. If so, a
guest author whose `configure` or `endpoint.start()` throws is told about a
field rather than about their bug.

## Before

```
arm                      witness                              other guest tests
rethrow removed          LateError: LateInitializationError:   9 of 9 pass
                         Local 'result' has not been
                         initialized.
```

Probe: `packages/transport/rpc_dart_wasm/example/wasm_guest/main.dart`, read
back over RPC by `example/integration_test/rpc_guest_test.dart`, on a booted
iOS 18.6 simulator.

**Measured on a device because there is nowhere else.** `rpc_wasm.dart` is
`dart:js_interop` and never executes on the VM: `melos run test:wasm` is
`flutter test`, `test:web` excludes this package, and `analyze` only compiles
it. Before this round nothing in the repository had ever RUN a line of it except
the happy path.

## Mechanism

`runZonedGuarded(body, handler)` routes a synchronous throw from `body` to
`handler` and returns `null`. The zone is there for a real reason — an unawaited
failing Future inside guest code surfaces as an ERROR rather than dart2wasm's
INFO-level print, which a previous round measured — but it was wrapped around
the boot as well as around the guest's later life, and the boot's errors belong
to the caller.

## After

```
arm                      witness                              other guest tests
fixed                    StateError: Bad state: configure      9 of 9 pass
                         exploded on purpose
```

`melos run test:wasm:device`: `+18`, one more than the `+17` baseline. The boot
error is also written to `console.error` before being rethrown, because an
exception escaping a guest's `main` is printed by dart2wasm's own handler at
INFO level — the exact thing the zone was added to fix.

## Canary

Two halves, two canaries, and the second exists because the first one's witness
could not be written without it.

```
the rethrow removed
  Expected: contains 'configure exploded on purpose'
    Actual: 'LateError: LateInitializationError: Local \'result\'
             has not been initialized.'
  +17 -1   the one witness, everything else green

the bridge cleanup removed
  +9 -9    every guest RPC test dies; the witness never runs
```

They fail differently, which is what makes them two halves rather than one.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:wasm` `+44`; `melos run test:unit --no-select` SUCCESS at load
15.94; `melos run format:check` SUCCESS; `melos run license:check` 1350/1350.

And the one that matters here: **`melos run test:wasm:device` `+18`** on a
booted iOS 18.6 simulator, against a dart2wasm guest built in the same run. The
baseline before this round was `+17`.

Android was NOT run: only the iOS simulator was booted, and the emulator this
machine has was offline. The change is Dart-only and touches no native code, so
`analyze:native` was not needed either — but the platform asymmetry is worth
naming rather than leaving implied, per the config's rule that the two device
scripts share no code.

## Not fixed

Nothing outstanding, but the second half is worth stating as a FINDING and not
only as a fix. Writing the witness exposed it: the guest calls `run` twice, which
the code explicitly permits after a failure — `_boot`'s catch sets
`_initialized = false` — and the retry did not work. `endpoint.close()` reaches
the bridge only after several awaits, while the retry installs its own
`rpcWasmReceiveBytes` synchronously, so the late close deleted the LIVE handler
and every host-to-guest byte went nowhere. `_RpcWasmBridge.close()` releases the
JS global before its first await, so closing the bridge directly frees the name
while the failed call still owns it.

**A recovery path nobody had ever taken.** `_initialized = false` is a promise,
and the only way to find out it was empty was to take it.

## Links

Lens `../lenses/RPC-13-unhandled-async-error.md` (seventh application; the first
from the catching side rather than the throwing side).
Bench `../probes/P-48-boot-failure-on-a-real-guest.md`, new.
Measurement checklist item D2, which states the rule this round is an instance
of. Catalog shape U-15 — drive the lifecycle twice.
