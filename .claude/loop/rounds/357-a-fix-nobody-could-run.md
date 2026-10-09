---
round: 357
verdict: INCONCLUSIVE
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — the bench is a booted iOS simulator, and none could be started; what was tried is listed below and in B-38
commit: yes
---

# Round 357 — a fix nobody could run

## Target

The owner's 6.0.0 review list, P1 item 7: the iOS recv loop does not restart
after a reject and does not report death.

RPC-06, whose Ask is the whole reason this round ends the way it does: *was this
code RUN, or only read and compiled?* It was read and compiled. It was not run.

## Hypothesis

`_startRecvLoop`'s `.catch` sets `_recvRunning = false` and returns.
Host-to-guest is that loop and nothing else, so a rejected poll ends the
direction with nothing restarting it and nothing reporting it — which
contradicts `RpcWasmBridge`'s contract that a dead runtime is reported so
in-flight calls are answered.

## Before

**The reading is conclusive and needs no device.** Android's driver loop already
catches, calls `reportDeath` and breaks, and its comment describes what iOS
still does:

> The driver used to log and break: the isolate stayed in `runtimes`, nothing
> further was evaluated, and Dart was never told -- so every in-flight call
> hung.

iOS does not even log. Two ways the pending `/recv` is failed while the runtime
is alive: `webView(_:stop:)` when WebKit cancels a scheme task for its own
reasons, and a second `/recv` failing the first with "superseded by new recv".

**The measurement is missing, and that is the verdict.** No number was taken,
because the only bench that can run this code is a device:

```
fvm flutter emulators --launch apple_ios_simulator   x5, silent success,
                                                      device never registered
waits of 45 s, 50 s, 60 s, 90 s, 240 s               no device
fvm flutter test integration_test -d "iPhone 16"      No supported devices found
fvm flutter doctor                                    Xcode 16.4 OK; connected
                                                      devices: macOS, Chrome
```

The simulator DID boot earlier in this same session — round 356 ran
`melos run test:wasm:device` on it twice for its canaries — and stopped coming
back afterwards. `xcrun simctl` and `open -a Simulator` are outside the
allowlist, so nothing available here can start it.

## Mechanism

Written up in full in `../backlog/B-38-ios-recv-loop-dies-silently.md`, along
with the fix, because the fix is worth more than the round.

## After

n/a — nothing was re-measured, because nothing was measured.

## Canary

n/a. **This is why the verdict is INCONCLUSIVE and not FIXED.** The fix was
written and `melos run analyze:native` returned `PASS swift / PASS kotlin`, and
round 348 already established what that is worth on its own: two green lines
from a gate never shown to fail. A native change nobody ran is exactly what this
project's config says must not ship.

**The fix is therefore REVERTED, not committed.** Keeping it would have put an
unwitnessed native change into a release the owner is preparing, behind a
verdict line that said it was fine.

## Gate

n/a — no code changed. The tree is as round 356 left it; only the journal moves.

## Not fixed

All of it, and the work is preserved rather than lost. B-38 carries the reading,
the sibling comparison, the four-step patch, the witness design, and the two
traps that cost the most to find:

- **`_nativeSetTimeout`, not `setTimeout`.** The next `<script>` tag DECLARES a
  `setTimeout` polyfill that queues into the guest's own timer table, and a
  function declaration hoists over the whole script — so a backoff written the
  obvious way makes the recv loop depend on the Dart event loop it feeds. The
  file already carries a comment about an earlier round that hit this hoisting.
- **Report death by `postMessage`, not by `fetch('rpc-wasm:///died')`.** The
  only caller is the recv loop giving up, and it gives up precisely because that
  scheme stopped answering.

The witness is designed and reachable: a guest method issuing a stray
`fetch('rpc-wasm:///recv')` supersedes the loop's pending task, which is a
rejection with the runtime alive — the same shape WebKit produces on its own.

## Links

Lens `../lenses/RPC-06-native-plugin-layers.md` — `applied:` gains 357, as every
verdict does; its STATUS is unchanged, because an INCONCLUSIVE round confirms
nothing. The lens's own Ask is what produced this verdict.
Lead `../backlog/B-38-ios-recv-loop-dies-silently.md`, new, reason "bench".
Catalog shapes U-13 and U-14 — the fix exists on the sibling platform.
