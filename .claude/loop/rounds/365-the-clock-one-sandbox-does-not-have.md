---
round: 365
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: P-56 — new
commit: yes
---

# Round 365 — the clock one sandbox does not have

## Target

The owner's list, item 8 and the iOS half of item 15, both unblocked when a
simulator came up mid-session. Taken together because one device run answers
both, and because the answer to one of them produced a defect neither asked
about.

RPC-06, whose Ask is *was this code RUN?* — and for the first time this session
the answer is yes on BOTH platforms, which is what turned a parity question into
a finding.

**Scope counted before the fix.** Three questions were open and the device
answered all three:

```
question                                      answer
item 8:  do guest frames arrive in order?     yes, 10k, both platforms
item 15: is a guest Timer throttled offscreen? no, neither platform
B-42:    does the 363 fix work on iOS?        yes, 5 of 5 witnesses
```

## Hypothesis

The item-15 hypothesis is the one that produced the round: a guest `Timer` in a
WKWebView that is never added to a view hierarchy sits on a permanently hidden
page, and WebKit throttles timers there. If it is throttled to 1 s, every
deadline, keepalive and backoff inside a guest is unusable on iOS.

## Before

Neither question had ever been measured. What the first attempt produced:

```
platform: ios              min       median    max
Timer(1 ms)                0.0ms     0.0ms     1.0ms
Timer(10 ms)               0.0ms     1.0ms     1.0ms
Timer(100 ms)              0.0ms     1.0ms     101.0ms
Timer(1000 ms)             53.0ms    99.0ms    101.0ms

platform: android          RpcStatusException(13): Internal server error
```

Probe: `packages/transport/rpc_dart_wasm/example/integration_test/guest_timer_lag_test.dart`.

**The iOS answer is the reassuring one and the Android arm is the finding.** The
identical guest, the identical call, threw on Android — so the round's subject
changed from "is iOS throttled" to "why can Android not run this at all".

## Mechanism

dart2wasm's glue calls `performance.now()` for the high-resolution clock —
`guest.mjs:123`, `_80: () => 1000 * performance.now()`. A WKWebView is a full
browser environment and supplies it. `JavaScriptSandbox` is a bare V8 isolate
with no DOM and no `performance` global, and neither boot script defined one.

So **any guest using `Stopwatch` — or any Dart API on the high-resolution clock
— crashes on Android and works on iOS**, with an opaque `Internal server error`
and nothing naming the cause. This was the first guest code in the repository to
use one.

## After

```
platform: android          min       median    max
Timer(1 ms)                2.0ms     3.0ms     8.0ms
Timer(10 ms)               3.0ms     4.0ms     8.0ms
Timer(100 ms)              4.0ms     5.0ms     6.0ms
Timer(1000 ms)             5.0ms     7.0ms     12.0ms
```

A `Date.now()` shim, installed only when `performance` is absent so a future
sandbox that supplies the real one is untouched. Millisecond resolution where
the real API is microsecond, which is the honest floor available here — a guest
timing sub-millisecond intervals now sees 0 rather than a wrong number.

And the two answers the round was sent for:

- **Timers are not throttled on either platform.** iOS is tighter at short
  delays and drifts ~10% on a 1 s timer; Android is a flat few ms.
- **10k frames arrive in order on both**, 2.2-2.8 s on Android and 5.0-14.7 s on
  iOS.

## Canary

The shim disabled in place (`if (false && typeof performance === 'undefined')`):

```
The following RpcStatusException was thrown running a test:
RpcStatusException(13): Internal server error
  a guest Timer is not throttled into uselessness
```

Which is also the exact message the defect produces in the field, so the canary
doubles as the record of what a user would see.

## Gate

`melos run analyze:native` PASS swift / PASS kotlin;
**`RPC_WASM_DEVICE=emulator-5554 melos run test:wasm:device` `+24 ~2`**;
**`RPC_WASM_DEVICE="iPhone 16 Plus" melos run test:wasm:device` `+26`** on an
iOS 18.6 simulator — the first two-platform device gate in this session;
`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`melos run test:wasm` all passed; `melos run format:check` SUCCESS;
`melos run license:check` compliant.

## Not fixed

**Item 8's defensive fix is deliberately NOT applied, and the measurement is
why.** The item proposes chaining the iOS `fetch` calls into a promise chain
because the ordering rests on an undocumented WebKit convention. Measured, the
convention holds over 10000 frames. Chaining would serialise every send —
removing the pipelining that the 5.0 s iOS figure depends on — which is a speed
trade, and the config's standing owner requirement is to ASK before trading
speed. Filed as `../backlog/B-43-ios-send-order-is-a-convention.md` with the
numbers, so the decision is made on them rather than on a worry.

**B-42 is closed by this round**: the iOS half of round 363's fail-fast passes
all five of its witnesses on the simulator.

## Links

Lens `../lenses/RPC-06-native-plugin-layers.md`, sixth application.
Benches `../probes/P-56-guest-timer-lag.md` and
`../probes/P-57-guest-to-host-frame-order.md`, both new.
Lead `../backlog/B-43-ios-send-order-is-a-convention.md`, new; closes
`../backlog/B-42-ios-strip-failfast-unwitnessed.md`.
Catalog shape U-19, the parity matrix — the defect is the cell where one
platform supplies a global the other does not.
