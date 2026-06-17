## 0.2.2

- Web-correctness verification: the client transport (`RpcWebSocketCallerTransport` / `RpcWebSocketChannel`) is confirmed dart2js-safe. No `dart:io` on the client path; the frame multiplexer header uses only 32-bit `ByteData` ops (no `setUint64`/`getUint64`), so it is safe under dart2js' 32-bit integer semantics.
- Added `test/websocket_web_smoke_test.dart`: frame round-trip plus caller/responder round-trips over an in-memory `WebSocketChannel` pair (no `dart:io`). Passes on VM, node, and chrome (`fvm dart test -p vm|node|chrome`).
- Added `async` and `stream_channel` dev dependencies for the in-memory channel pair used by the web smoke test.

## 0.2.1

- `RpcWebSocketServer`: added `onPeerEndpointCreated` callback — when set, each accepted connection creates an `RpcPeerEndpoint` instead of `RpcResponderEndpoint`, enabling bidirectional server-initiated calls over WebSocket.
- `RpcWebSocketCallerTransport.connect()`: now awaits `WebSocketChannel.ready` before returning, so connection errors are reported at connect time rather than leaking as unhandled stream errors.
- Updated to `rpc_dart: ^3.1.0`.

## 0.2.0

- Updated to `rpc_dart: ^3.0.0`.
- Migrated to 3-layer transport architecture (`IRpcChannel` / `IRpcMultiplexedChannel` / `RpcChannelTransport`).
- WebSocket metadata encoding switched to binary CBOR for consistency with core.

## 0.1.0

- Initial release: WebSocket caller/responder transports for rpc_dart (web-safe, works on Dart2JS/WASM).
