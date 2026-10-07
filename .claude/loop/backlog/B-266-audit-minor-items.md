---
status: open (round 714)
round: 714
commit: 0f167865
paths: [packages/transport/rpc_dart_wasm/android/src/main/kotlin/com/nogipx/rpc_dart_wasm/RpcDartWasmPlugin.kt, packages/transport/rpc_dart_wasm/ios/Classes/RpcDartWasmPlugin.swift, packages/transport/rpc_dart_isolate/lib/src/web_bridge.dart, packages/transport/rpc_dart_http/lib/src/rpc_http_responder_transport.dart, packages/transport/rpc_dart_http2/lib/src/transports/http2/rpc_http2_caller_transport.dart]
probe: none
reason: "unmeasured — low-severity findings of the audit after round 710, by reading"
---

# B-266 — audit minor items

Each read, none measured; listed so they are not lost.

1. **Android, an isolate leaks if setup throws.** `registerByteChannel` and
   `provideNamedData` run before the `try` in `RpcDartWasmPlugin.kt`; a throw
   other than termination leaves the isolate in `runtimes`, and Dart's
   `_release()` on a failed load never sends `closeRuntime`.
2. **iOS, the host's 1 MiB send-queue limit has no effect.** Swift answers
   `/send` at once into an unbounded `recvQueue`; against a guest that stops
   polling, memory is bounded by flow control alone.
3. **Web worker under dart2wasm, payloads are JS-backed views.**
   `isolate_manager` dartifies a `Uint8Array` into a JS-backed list; a user
   codec calling `sublist` on the payload meets the SDK double-offset bug
   (B-256's class). Core's own CBOR is hardened.
4. **http1, no total cap on buffered request bodies.** Each body up to
   `effectiveMaxBufferedBytes` (16 MiB), up to `maxActiveStreams` (4096) of
   them: 60 stalled 16 MiB bodies measured 595 MiB RSS.
5. **http2 caller, the TLS-through-proxy timeout may not close its socket.**
   It calls `rawSocket.destroy()` after `SecureSocket.secure` took the socket
   over; round 712 measured that pattern not to close a server-side socket.
6. **websocket, the compression path is unguarded.** With compression on the
   server takes dart:io's transformer: no message ceiling and no ping limit.

## Owner decision

—
