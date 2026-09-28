---
round: 492
commit: e8acaadb
paths: [packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt, packages/transport/rpc_dart_wasm/lib/src/rpc_flutter_wasm_bridge.dart, packages/core/rpc_dart/lib/src/rpc/transports/frame_multiplexed_channel.dart]
scope: [rpc_dart_wasm]
---

# C-57 — a large host-to-guest frame keeps its place, on both platforms

Bench: `../probes/P-131-does-a-large-host-to-guest-frame-keep-its-place.md`.

> **Scope**: Flutter 3.38.3, Android emulator API 30 and an iOS 18.6 simulator,
> the example host app with the real dart2wasm guest. Frames of 192 KiB against
> a 64 KiB threshold.

## The claim that was checked

B-101: *"a small frame reaches the guest before a large one sent earlier, which
on a byte stream corrupts framing."*

The code is as the lead describes it. `forwardBytesToRuntime` has two paths with
different latencies — at or above `NAMED_DATA_THRESHOLD` the bytes go through
`provideNamedData` and an async JS IIFE that AWAITS
`consumeNamedDataAsArrayBuffer`, below it through a synchronous
`_rpcWasmReceiveBytesB64`. Each inbound platform message gets its own
`scope.launch`. And **nothing above serialises**: neither
`RpcFrameMultiplexedChannel.send` nor `RpcFlutterWasmBridge.send` holds a lock,
both confirmed by reading.

## The numbers

```
                    peak in flight   overlapped   >=64 KiB   result
android  1 big + 50 small     52         152          1      all echoes correct
android  5 big + 50 small x3 110         492         15      all echoes correct
ios      5 big + 50 small x3  56         329         15      all echoes correct
```

165 calls per platform, every answer matched its own request, the channel usable
afterwards.

## Control

**The precondition is asserted, which is what makes this a negative rather than a
run that proved nothing.** A `_CountingBridge` decorator counts forwards in
flight and the test FAILS if the peak is not above 1 — so "the ordering holds"
cannot be confused with "the two paths never overlapped", and 15 of the
overlapping frames were over the threshold on each platform.

This matters more than usual here because the lead's mechanism is a race: a green
run with no concurrency is the expected result of a bench that did not drive it,
and it looks identical to a negative.

## What this does NOT settle

**WHY it holds is unverified.** The reading is that
`androidx.javascriptengine` evaluates one script per isolate and
`evaluateJavaScriptAsync` completes only once the IIFE's promise settles, so the
large path's `_rpcWasmReceiveBytes` runs before the next script starts. That is a
property of the DEPENDENCY, not of this code, and nothing here measured it. If it
is the explanation, an androidx version that parallelises evaluation reopens the
lead — and P-131 is what would say so.

The iOS column holds for a different reason again (WebKit's dispatch order for
URL-scheme fetches), which `guest_to_host_order_test.dart` already records as
conventional rather than contractual for the other direction.

**A large frame concurrent with an unawaited flow-control GRANT** is named by the
lead as a trigger and is not pinned. Grants are small and were certainly among
the overlaps counted, but nothing asserts one specifically.

So the fix sketch — a Mutex per runtime, or routing every frame through named
data — is NOT needed today and would cost serialised forwards. Left undone
deliberately.
