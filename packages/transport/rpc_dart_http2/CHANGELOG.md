## 0.2.0

- Updated to `rpc_dart: ^3.0.0`.
- gRPC wire compliance fixes: correct trailers framing, binary headers, Trailers-Only responses.
- `RpcHttp2Server`: supports `RpcReflectionRegistry.attachTo()` for gRPC Server Reflection.

## 0.1.0

- Initial release: HTTP/2 caller/responder transports and `RpcHttp2Server` for rpc_dart.
