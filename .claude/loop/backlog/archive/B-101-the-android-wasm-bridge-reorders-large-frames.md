---
status: closed (round 492)
round: 492
commit: e8acaadb
paths: [packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
probe: P-131
reason: "closed — NOT reproduced on either platform with the overlap proven present; negative in checked/C-57, with the unverified dependency property that would reopen it"
---

# B-101 — Android wasm: a frame of 64 KiB or more can be overtaken by a smaller one

**Filed from the external audit of 2026-09-28** (core + transports, read in full,
transport findings re-checked against the code). Confidence from reading:
**medium-high**. Nothing here was measured; the witness below is the first
thing a round owes this lead, and it may refute it.

Frames at or above `NAMED_DATA_THRESHOLD` are delivered through an async JS function that awaits `consumeNamedDataAsArrayBuffer`, smaller ones synchronously via base64; each platform message runs in its own `scope.launch`, and sends from different streams (and unawaited flow-control grants) are not serialised — so a small frame reaches the guest before a large one sent earlier, which on a byte stream corrupts framing.

## The shape

`packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt:476-490`:

```kotlin
if (bytes.size >= NAMED_DATA_THRESHOLD) {
    isolate.provideNamedData(name, bytes)
    isolate.evaluateJavaScriptAsync("""(async function() {
        var buf = await android.consumeNamedDataAsArrayBuffer('$name');
        _rpcWasmReceiveBytes(new Uint8Array(buf)); ...})()""").await()
} else {
    isolate.evaluateJavaScriptAsync("_rpcWasmReceiveBytesB64('$b64')").await()
}
```

`:540-575`: every message gets its own `scope.launch` on `Dispatchers.Main`.
`RpcFlutterWasmBridge.send` awaits the reply per message
(`lib/src/rpc_flutter_wasm_bridge.dart:243-256`), but `RpcFrameMultiplexedChannel.send`
does not serialise across streams and grants are `unawaited`.

## Why it matters

The guest's channel is a BYTE stream reassembled by `RpcFrameMultiplexedChannel`:
a 9-byte header followed by the wrong frame's bytes is a framing error that closes
the connection, or worse, parses. Triggered by any large message concurrent with
any other frame — a grant, a second call's headers.

## Witness a round would build

Device test: one 1 MiB unary request concurrently with 50 small unary requests
from the host; guest echoes. Expected today: a framing failure or a mismatched
echo within a few runs.

## Fix sketch

Serialise forwards per runtime (a `Channel`/`Mutex` in Kotlin), or route every
host→guest frame through named data so both paths have one ordering.

## Owner decision

—

## Closed (round 492) — the shape is real, the defect is not

Every structural claim in this lead was confirmed by reading, including the one
it rests on: **nothing serialises above the plugin.**
`RpcFrameMultiplexedChannel.send` encodes and awaits with no lock, and
`RpcFlutterWasmBridge.send` awaits its own platform reply with no lock either, so
concurrent callers do overlap.

The reorder still did not happen:

```
                    peak in flight   overlapped   >=64 KiB   result
android  1 big + 50 small     52         152          1      all echoes correct
android  5 big + 50 small x3 110         492         15      all echoes correct
ios      5 big + 50 small x3  56         329         15      all echoes correct
```

**The overlap is asserted, not assumed.** The bench fails if forwards in flight
never peak above 1 — for a race, a green run that did not create the concurrency
is indistinguishable from a negative, and the first version of this round would
have reported clean from a peak of 1.

**What is NOT established is why**, and that is the part to read before trusting
this. The likely explanation is that `androidx.javascriptengine` evaluates one
script per isolate and `evaluateJavaScriptAsync` completes only once the async
IIFE's promise settles, so the large path delivers before the next script starts.
That is a property of the DEPENDENCY and nothing here measured it. An androidx
version that parallelises evaluation reopens this lead;
`host_to_guest_order_test.dart` is what would say so, and it now runs in
`test:wasm:device` on both platforms.

The fix sketch is deliberately NOT applied: a Mutex per runtime would serialise
every host-to-guest forward for a race that does not occur.

Not pinned: a large frame concurrent with an unawaited flow-control GRANT
specifically. Grants are small and were certainly among the overlaps counted, but
no assertion isolates one.
