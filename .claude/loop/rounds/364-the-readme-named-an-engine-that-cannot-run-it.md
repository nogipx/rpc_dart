---
round: 364
verdict: FIXED
packages: [rpc_dart_wasm, rpc_dart_websocket]
lens: RPC-23
bench: P-55 — new
commit: yes
---

# Round 364 — the README named an engine that cannot run it

## Target

The owner's 6.0.0 review list, P2 item 15 — four separate asks filed as one
line. Split by what could be measured, and the split is stated up front rather
than discovered at the end:

```
ask                                        verdict
wasm README: WKWebView not JavaScriptCore  FIXED
wasm README: the price of a frame          FIXED, measured on Android
wasm README: offscreen Timer latency       NOT DONE — iOS only, no simulator
ws README: behind a frame-limiting proxy   FIXED, and verified by measurement
```

RPC-23: the narrative beside the code, gone stale. Its rule is that prose is a
secondary source — and here the prose did not merely drift, it named a component
that **cannot do the job at all**.

## Hypothesis

The README says the iOS backend is JavaScriptCore. JSC has no WebAssembly, so if
that were true this package could not run a dart2wasm guest on iOS — and it
does. Therefore the README is wrong, and a reader choosing a transport on it is
reasoning from a false premise.

## Before

```
README line 71   - iOS: `JavaScriptCore`
README line 115  - Flutter plugin backend: JavaScriptCore on iOS, ...
```

The code says otherwise in both plugins: `WKWebView` with a custom `rpc-wasm:`
scheme handler, bytes crossing as `fetch` — POST out, long-polled GET in.

And the cost question the item asks about had NO answer in the README at all, so
a reader had to guess. Measured instead, with
`packages/transport/rpc_dart_wasm/example/integration_test/frame_cost_test.dart`:

```
platform: android            (Android 11, API 30, emulator)
shape             n       p50      p95      p99
empty unary       n=200   12.9ms   50.8ms   153.0ms
1 KiB response    n=200   12.3ms   66.3ms   214.2ms
64 KiB response   n=100   15.5ms   94.2ms   556.3ms
1 MiB response    n=20    114.9ms  903.3ms  903.3ms
```

## Mechanism

A README written against an intended design and never re-read against the
shipped one. Two mentions, both wrong the same way, which is what a search for
the component name catches and a read-through does not.

## After

Both mentions corrected, with the reason JSC is impossible stated so the error
cannot come back: *"JSC has no WebAssembly, so it cannot run a dart2wasm guest
at all."* The cost table is published with its hardware named, and what it is
for: read the SHAPE — flat to 1 KiB, because the price is the boundary and not
the payload; p99 roughly ten times p50, because a call can miss a driver tick.

The websocket README gains the proxy note, and the claim under it was verified
rather than asserted — see below.

## Canary

n/a in the usual form: documentation has no switch to flip. Its equivalent is
that every claim written was checked against the code or measured, and the one
that could be wrong was:

```
"dart:io buffers a whole message before the frame layer sees a byte"
  ->  peer sent        = 96.0 MiB in one WebSocket message
      chunks delivered = 1
      first chunk size = 96.0 MiB
```

That claim came from a comment in `frame_multiplexed_channel.dart`, which is
exactly the kind of source this lens says not to trust. Running the existing
probe turned it into a measurement before it went into a README people deploy
from. Likewise `RpcWebSocketServer` was grepped for a connection limit before
the README stated there is none.

## Gate

`melos run analyze` SUCCESS over 21 packages plus rpc_dart_wasm;
`RPC_WASM_DEVICE=emulator-5554 melos run test:wasm:device` **`+22 ~2`**, one new
test on top of `+21`; `melos run test:wasm` all passed;
`melos run format:check` SUCCESS; `melos run license:check` compliant.

## Not fixed

**The offscreen-WKWebView timer latency, which is the item's headline
measurement.** WebKit throttles timers in hidden pages and the amount is
unestablished for this plugin; a guest whose `Timer`s are being delayed by
seconds would change how the transport should be used. It needs an iOS
simulator, which has refused every launch attempt this session.

Rather than leave that silent, the README says so in the place a reader would
otherwise assume parity: *"The equivalent iOS numbers are not measured, and
neither is the latency a guest `Timer` sees while the WKWebView is offscreen.
Do not assume parity with the table above."* An absent number that announces
itself is worth more than one quietly extrapolated from the other platform.

Tracked with the other simulator-blocked work in
`../backlog/B-42-ios-strip-failfast-unwitnessed.md` and
`../backlog/B-38-ios-recv-loop-dies-silently.md`.

## Links

Lens `../lenses/RPC-23-the-narrative-beside-the-code.md`, seventeenth
application.
Bench `../probes/P-55-what-a-wasm-call-costs.md`, new.
Probe reused: `ws_chunk_is_peer_controlled.dart`, to verify the proxy note.
Catalog shape U-22.
