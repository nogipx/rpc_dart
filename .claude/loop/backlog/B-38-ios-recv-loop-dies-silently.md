---
status: decided by owner (round 415)
round: 357
commit: 0f05352a
paths: [packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift]
probe: packages/transport/rpc_dart_wasm/example/wasm_guest/main.dart
reason: "bench — the witness needs a booted iOS simulator and none could be started in this session: `flutter emulators --launch apple_ios_simulator` returned silently five times and the device never registered, and `xcrun simctl` / `open -a Simulator` are outside the allowlist. The fix is written below and type-checks; it is not committed, because a native change nobody ran is exactly what this project's config says must not ship"
---

# B-38 — the iOS recv loop gives up silently, and Android already fixed this

## The finding, which needs no device

`RpcDartWasmPlugin.swift`, in the boot HTML:

```js
function _startRecvLoop() {
  if (_recvRunning) return;
  _recvRunning = true;
  (function poll() {
    fetch('rpc-wasm:///recv').then(function(r) {
      return r.arrayBuffer();
    }).then(function(buf) {
      _rpcWasmReceiveBytes(new Uint8Array(buf));
      poll();
    }).catch(function(e) {
      _recvRunning = false;        // <- and that is all
    });
  })();
}
```

Host-to-guest is this loop and nothing else, so where it stops the direction
stops. Nothing restarts it and nothing reports it, so `recvQueue` grows on the
Swift side and every in-flight call waits out a deadline that is OPTIONAL on
this transport.

**The sibling already fixed it, and its comment describes the iOS behaviour**
(`RpcDartWasmPlugin.kt`, `startDriver`):

> The driver used to log and break: the isolate stayed in `runtimes`, nothing
> further was evaluated, and Dart was never told -- so every in-flight call
> hung. A sandbox that dies (IsolateTerminatedException, sandbox process
> killed) arrives here and nowhere else.

Android catches, calls `reportDeath(runtimeId, ...)` and breaks. iOS does not
even log. This is U-13/U-14 exactly: a fix made on one platform and never
ported, in a package whose config says the two device scripts share no code.

It also contradicts `RpcWasmBridge`'s own contract, which promises a dead
runtime is reported so in-flight calls are answered.

## How the reject is reachable without the host stopping

`SchemeHandler` holds ONE pending `/recv` task. Two ways it is failed while the
runtime is alive:

- `webView(_:stop:)` nils `pendingRecvTask` when WebKit cancels a scheme task
  for its own reasons — a navigation, memory pressure, a backgrounded view.
- a second request for `/recv` fails the first with
  `didFailWithError(code -5, "superseded by new recv")`.

The second is reachable from inside the guest, which is what makes a witness
possible at all.

## The fix, written and type-checked but NOT committed

`melos run analyze:native` on it: `PASS swift / PASS kotlin`. Reapply as:

1. **A `_rpcReportDied(reason)` helper** beside `_rpcReportBoot`, posting to a
   new `rpcDied` script message handler.
   **A postMessage, NOT `fetch('rpc-wasm:///died')`** — the only caller is the
   recv loop giving up, and it gives up precisely because that scheme stopped
   answering. Wrap it in try/catch with a `console.error` fallback.
2. **Retry in the `.catch`**: count consecutive failures, reset the count on any
   successful poll, and past 5 set `_recvRunning = false` and
   `_rpcReportDied(...)`. Retry first because a WebKit cancellation is often
   transient and the runtime is alive.
   **Back off through `_nativeSetTimeout`, NOT `setTimeout`** — the next
   `<script>` tag DECLARES a `setTimeout` polyfill that queues into the guest's
   own timer table, and a function declaration hoists over the whole script, so
   backing off through it makes the recv loop depend on the Dart event loop it
   feeds. The file already carries a comment about a previous round that lost a
   day to exactly this hoisting.
3. **Register and unregister `rpcDied`** alongside `rpcBoot`/`rpcConsole` in the
   `WasmRuntime` initialiser and in `close()`.
4. **Route it** in `userContentController(_:didReceive:)`:
   `if booted { reportDeath(reason) } else { finishBoot(reason) }` — the same
   split every other pre-boot failure uses.

## The witness, also written

`example/wasm_guest/main.dart` gains a `BreakRecvLoop` unary method that issues
a stray `fetch('rpc-wasm:///recv')` through `dart:js_interop`, superseding the
loop's pending task. The integration test then: a normal call (control), the
break, a 500 ms wait for the backoff, and a normal call again. iOS only —
Android drives host-to-guest over Binder with no pending-task slot, so there is
nothing to supersede and the test returns early on `!Platform.isIOS`.

## What was tried for a device, so it is not retried blindly

```
fvm flutter emulators --launch apple_ios_simulator   x5, silent success,
                                                      device never registered
waits of 45 s, 50 s, 60 s, 90 s, 240 s               no device
fvm flutter test integration_test -d "iPhone 16"      "No supported devices
                                                      found with name or id"
fvm flutter doctor                                    Xcode 16.4 OK,
                                                      "Connected device (2)":
                                                      macOS and Chrome only
```

The simulator DID boot once earlier in the same session (iPhone 16, iOS 18.6)
and `melos run test:wasm:device` ran `+18`, so the path works; it stopped coming
back after that run. `xcrun simctl` and `open -a Simulator` are outside this
session's allowlist, so nothing here can start it.

## Owner decision

**None needed on the fix — it needs a device, not a decision.** Boot a simulator
and the round finishes: reapply the four steps above, run
`melos run test:wasm:device` for the witness, then two canaries (drop the retry,
drop the report) which must fail differently. Run it on Android too, which this
session never could: the emulator was offline the whole time.

**Settled in the backlog review: the OWNER boots it.** `xcrun simctl` and
`open -a Simulator` are outside the agent's allowlist and five
`flutter emulators --launch` attempts registered nothing, so the blocker is not
something a round can retry its way through.

Shipping on `analyze:native` alone was offered and declined, which is the right
way round — round 348 established what a gate never shown to fail is worth, and
this is a native change on a path whose whole defect is that it fails silently.

So this is `decided by owner` and waiting on one action, not on a judgement.
When the simulator is up, the round runs BOTH platforms: the two boot scripts
are separate strings in separate languages, so a fix to one is never a fix to
the other.
