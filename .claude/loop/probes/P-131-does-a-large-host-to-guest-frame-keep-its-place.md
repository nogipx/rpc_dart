---
file: packages/transport/rpc_dart_wasm/example/integration_test/host_to_guest_order_test.dart
round: 492
commit: e8acaadb
paths: [packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt, packages/transport/rpc_dart_wasm/lib/src/rpc_flutter_wasm_bridge.dart]
status: valid
---

# P-131 — does a large host-to-guest frame keep its place?

## Why it exists

`guest_to_host_order_test.dart` asks the same question in the other direction and
has for many rounds. Host-to-guest was never asked, and on Android it is the
riskier direction: the forward has TWO paths with different latencies — named
data plus an async JS IIFE at or above 64 KiB, a synchronous base64 eval below
it.

## The harness

The example app's real dart2wasm guest, `Echo.Say`, driven through
`RpcFlutterWasmBridge`. Per burst: 5 requests of 192 KiB and 50 small ones,
issued in ONE turn so the plugin sees them concurrently; 3 bursts. Every answer
is checked against its own request, and a final call checks the channel still
works.

**The bench asserts its own PRECONDITION**, which is the part worth copying. A
`_CountingBridge` decorator wraps the real bridge and counts forwards in flight;
the test fails if the peak is not above 1. Without it, "the ordering holds" and
"the two paths never overlapped" produce the same green, and they are opposite
conclusions. Nothing in the library serialises here — neither
`RpcFrameMultiplexedChannel.send` nor `RpcFlutterWasmBridge.send` holds a lock —
so the overlap had to be demonstrated rather than assumed.

## The numbers (round 492, Android emulator API 30)

```
                    peak in flight   overlapped frames   >=64 KiB   result
1 big + 50 small          52               152              1       all echoes correct
5 big + 50 small, x3     110               492             15       all echoes correct
```

165 calls, every answer matched its own request, the channel usable afterwards.

## Measures

Forwards in flight at once, and how many of the overlapping ones were over the
named-data threshold. Then correctness of each echo — which on a byte stream is
the ordering check, since a frame delivered out of order makes the next 9 bytes
read as a header from the middle of somebody else's payload.

## Control

The precondition assertion IS the control here, inverted: it establishes that the
conditions for the defect were present. A run with `peak in flight == 1` fails
rather than passing, so the negative cannot be produced by a bench that did
nothing.

## What it establishes, and what it does not

Establishes: with 15 large frames genuinely overlapping smaller ones, none was
overtaken on Android.

Does NOT establish WHY. The reading is that `androidx.javascriptengine`
evaluates one script per isolate and `evaluateJavaScriptAsync` completes only
when the IIFE's promise settles, so the large path's delivery precedes the next
script — **unverified**, a property of the dependency rather than of this code.
If it is right, an androidx version that parallelises evaluation reopens the
lead; the test is what would say so.

Does NOT cover a large frame concurrent with an unawaited flow-control GRANT
specifically, which the lead names as a trigger. Grants are small and were
certainly among the 492 overlaps, but nothing here pins one.

## Reading

(round 492), rpc_dart_wasm — 5 frames of 192 KiB and 50 small ones issued in
ONE turn, three bursts, on a device. **Its `_CountingBridge` decorator asserts
the bench's own precondition**: forwards in flight must peak above 1, or the
run proves nothing about ordering. Copy that anywhere the hypothesis is a RACE
— a bench that failed to drive the concurrency is green in exactly the way a
negative is
