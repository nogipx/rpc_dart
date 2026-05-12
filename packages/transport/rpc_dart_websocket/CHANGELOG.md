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
