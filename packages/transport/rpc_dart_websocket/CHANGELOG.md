## 0.2.0

- Updated to `rpc_dart: ^3.0.0`.
- Migrated to 3-layer transport architecture (`IRpcChannel` / `IRpcMultiplexedChannel` / `RpcChannelTransport`).
- WebSocket metadata encoding switched to binary CBOR for consistency with core.

## 0.1.0

- Initial release: WebSocket caller/responder transports for rpc_dart (web-safe, works on Dart2JS/WASM).
