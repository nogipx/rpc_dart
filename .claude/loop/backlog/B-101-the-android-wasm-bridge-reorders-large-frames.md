---
status: open
round: — (not re-measured) — filed by the external audit of 2026-09-28
commit: 8253fe8a
paths: [packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt]
probe: none — static read, nothing run
reason: "bench — filed from a static read (external audit, 2026-09-28, intake 8253fe8a); the auditing container had no Dart SDK, so nothing here was run and the witness below is unbuilt"
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
