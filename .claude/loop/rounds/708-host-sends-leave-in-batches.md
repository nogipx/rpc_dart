---
round: 708
verdict: FIXED
packages: [rpc_dart_wasm]
lens: RPC-06
bench: none — the device probe from round 707 (`.dart_tool/probe/zz_probe_frame_rate.dart.txt`), 2000 frames of about 1 KiB each way plus a 10000-frame burst of tiny ones, on the Android emulator
commit: yes
release: changelog
severity: S2
---

# Round 708 — host sends leave in batches

## Target

B-168, the Android half: the host-to-guest byte path pays one JavaScript
evaluation per frame.

## Hypothesis

The host bridge's `send` awaits each platform-channel reply before the next
frame can go, so host-to-guest runs at one frame per native round trip -- on
Android, one `evaluateJavaScriptAsync` each.

## Before

Android emulator (API 30):

```
round 0  guest->host 201 f/s   host->guest 30 f/s
round 1  guest->host 404 f/s   host->guest 26 f/s
round 2  guest->host 412 f/s   host->guest 28 f/s
tiny host->guest burst of 10000: not finished within the 10-minute test budget
```

## Mechanism

As hypothesised.

## Fix

`RpcFlutterWasmBridge.send` queues the frame and returns; one pump sends what
has queued as one platform message -- up to 64 frames and 64 KiB, a larger
frame alone -- and awaits its reply before the next. Safe because the bridge is
a byte stream the guest reassembles. `send` waits only when more than 1 MiB is
queued, so memory stays bounded against a peer without flow control. Applies
to iOS too.

`rpc_guest_test` "closing during a stream RAISES" closed its stream after a
fixed 400 ms and then required at least one item to have arrived. It now waits
for the first item (up to 30 s) before closing. Measured before changing it,
the Firehose items seen by 400 ms: HEAD 0, 0, 0 in three runs; with the pump
3, 3, 65. The pump delivers sooner; the fixed 400 ms was a premise about the
device, and it failed once in a full Android run with the pump.

Tried and reverted: a faster JS base64 encoder for guest-to-host (an output
array joined in 8 KiB strings; checked equal to node's `Buffer` for every
length to 3000). It took guest-to-host from about 400 to 550-650 f/s, but with
it the same test passed 2 of 6 runs against 4 of 4 without, for a reason not
found. A smaller outbox budget (256 KiB) did not change that.

## After

```
round 0  guest->host 144 f/s   host->guest 349 f/s
round 1  guest->host 380 f/s   host->guest 490 f/s
round 2  guest->host 370 f/s   host->guest 513 f/s
tiny host->guest burst: 10000 of 10000
```

Host-to-guest about 15x; guest-to-host unchanged. Full device suite: Android
30 passed, 4 skipped; iOS 32 passed, 2 skipped.

## Canary

Before is the canary, on the same emulator and guest.

## The verdict questions

1. Yes: Before on the same tree.
2. Yes: the Android host-to-guest path the lead named.
3. Yes: frames per second, and every frame arriving.
4. Not zero-valued.
5. Yes, quoted; round 0 is warm-up.
6. One cause for this half.
7. Not a trade: nothing gets slower.
8. One test premise changed, stated above with its measurement.

## Gate

`analyze`, `test:wasm`, `test:wasm:device` on Android and iOS.

## Not fixed

Guest-to-host on Android stays at a few hundred 1 KiB frames a second: the
pure-JS base64 encoder, a drain per tick, and three evaluations per driver
tick. The one change measured to help it is reverted above.

## Links

Lead `../backlog/B-168-wasm-byte-transport-cost.md` closed.
Lens `../lenses/RPC-06-native-plugin-layers.md` -- `applied: [..., 708]`.
