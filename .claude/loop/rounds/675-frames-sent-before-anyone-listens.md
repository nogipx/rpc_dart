---
round: 675
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-20
bench: none — the device witness is the measurement: `example/integration_test/boot_frames_test.dart`, on the iOS 18.6 simulator and an Android API 30 emulator
commit: yes
release: changelog
---

# Round 675 — frames sent before anyone listens

## Target

B-165, wasm in the owner's order. Two windows at boot, each named by the lead:

- host side: what the guest sends during `invokeMain` is pushed by native
  before `loadRuntime` returns, so before the Dart bridge exists to install its
  message handler;
- guest side: a frame the host sends before the guest installs
  `rpcWasmReceiveBytes` -- a guest that awaits anything before `RpcWasm.run`.

Both platforms, both sides: 4 sites (Dart `load`, the two native `loadRuntime`s,
the two boot scripts' `_rpcWasmReceiveBytes`).

## Hypothesis

Flutter buffers one message per channel that has no handler, dropping older
ones; the boot scripts drop a host frame when the guest has no receiver yet.

## Before

`boot_frames_test.dart`: a fake guest sends `[1]`, `[2]`, `[3]` from
`invokeMain`; a second installs its echo receiver 500 ms into `main` while the
host sends `[7, 8, 9]` at once.

```
iOS      boot frames received  [3]         early host frame echoed  []
Android  boot frames received  [3]         early host frame echoed  []
```

(Android's "before" is canary 1 and canary 2 below, one half each.)

## Mechanism

Host: the runtime id was chosen by native and returned by `loadRuntime`, so the
bridge -- and its handlers -- could only be built after boot. Guest:
`_rpcWasmReceiveBytes` had no else branch.

## Fix

- Dart chooses the runtime id (128 random bits) and builds the bridge, handlers
  included, before calling `loadRuntime`; a failed load releases them. Native
  uses the requested id when it is non-empty and unused; a reply with another
  id is refused.
- Both boot scripts hold frames that arrive with no receiver and deliver them,
  in order, on the next inbound frame or at the end of every
  `_flushMicrotasks` -- which every timer and every frame reaches, so a
  receiver installed in either gets them.

## After

```
iOS      boot frames received  [1, 2, 3]   early host frame echoed  [7, 8, 9]
Android  boot frames received  [1, 2, 3]   early host frame echoed  [7, 8, 9]
```

## Canary

- Canary 1, handlers installed after `loadRuntime` (the old order, id still
  Dart's): `boot frames received: [3]` on both platforms.
- Canary 2, the boot scripts drop a frame with no receiver: `early host frame
  echoed: []` on both platforms.

Each canary left the other half's test green. Restored: 2 of 2 green on both.

## The verdict questions

1. Yes: each canary removes one half; the other test is its control.
2. Yes: `[3]` against `[1, 2, 3]`; `[]` against `[7, 8, 9]`.
3. Yes: bytes at the Dart bridge's `incoming`.
4. Not zero-valued, except canary 2's `[]`, whose arm reads `[7, 8, 9]` with
   the fix -- the mechanism can emit.
5. Yes, quoted.
6. Two halves, two canaries, each on both platforms.
7. Yes.
8. None.

## Gate

`test:wasm` +47 (three test mocks now grant the requested id, as native does);
wasm `analyze` clean; `format:check` and `license:check` green; both native
sides compiled and ran on device. No workspace member changed, so `test:unit`
stands at round 674's green run.

`test:wasm:device`, full suite: iOS 1 red, Android 2 reds -- `rpc_guest_test`
"all four call shapes" (both) and `guest_to_host_order_test` (Android). Both are
red at the session-start commit `32974d54` too, run from a worktree with the
guest rebuilt there, and the first fails with this round's JS change reverted.
Filed as `B-254` and `B-255`, not part of this round.

## Not fixed

Nothing on B-165.

## Links

Lead `../backlog/B-165-wasm-frames-before-the-dart-handler-are-lost.md` closed.
Leads filed `../backlog/B-254-a-client-stream-to-a-wasm-guest-fails.md`,
`../backlog/B-255-ten-thousand-guest-frames-fail-on-android.md`.
Lens `../lenses/RPC-20-the-window-before-the-first-listener.md` -- `applied: [..., 675]`.
