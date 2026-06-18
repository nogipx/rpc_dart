## 0.2.2

Server-side hardening and a per-stream error-routing correctness fix.

- BUG A (security policy reachable): `RpcHttp2Server` now accepts a
  `RpcSecurityPolicy` (default `const RpcSecurityPolicy()`) and forwards it to
  every `RpcHttp2ResponderTransport`. Previously the server always used the
  default policy with no way to set one, so `maxMessageLengthBytes` /
  `maxActiveStreams` were effectively unreachable. Also exposed on
  `RpcHttp2Server.createWithContracts`.
- BUG B (per-stream error isolation): the caller and responder transports share
  a single broadcast `StreamController` for `incomingMessages`, and
  `getMessagesForStream` filtered it by `streamId`. Because `.where()` does not
  filter errors, an error on one stream was delivered to EVERY stream's
  subscriber (a parse error on stream 3 surfaced as an error on stream 5).
  Per-stream errors are now wrapped in `RpcHttp2StreamError` and routed only to
  the owning stream via `filterStreamEvents`; connection-level fatal errors
  still fan out to all subscribers (correct). Public
  `incomingMessages` / `getMessagesForStream` API is unchanged.
- BUG C (TLS / h2): `RpcHttp2Server` accepts an optional `SecurityContext`.
  When provided it binds a `SecureServerSocket` advertising ALPN `h2` instead
  of a plaintext `ServerSocket`; plaintext h2c remains the default. Added
  `RpcHttp2Server.isSecure`. Added `RpcHttp2CallerTransport.viaSocket(...)` so a
  TLS `SecureSocket` (with custom cert validation/pinning) can back the caller
  transport. Note: ALPN negotiation works at the wire level, but
  `SecureSocket.selectedProtocol` may report `null` on some platforms (observed
  on the macOS Dart VM); the TLS h2 round-trip itself is verified by tests.
- Fixed a latent "Concurrent modification during iteration" crash in
  `RpcHttp2Server.stop()` (endpoint list mutated by `socket.done` during close).
- `RpcHttp2Server.port` now returns the OS-assigned port after binding when
  constructed with port `0`.

## 0.2.1

- `RpcHttp2CallerTransport`: added optional `proxyUri` parameter to both `secure` and `insecure` constructors — supports HTTP CONNECT proxy tunneling with optional Basic auth from URI userinfo.
- Updated to `rpc_dart: ^3.1.0`.

## 0.2.0

- Updated to `rpc_dart: ^3.0.0`.
- gRPC wire compliance fixes: correct trailers framing, binary headers, Trailers-Only responses.
- `RpcHttp2Server`: supports `RpcReflectionRegistry.attachTo()` for gRPC Server Reflection.

## 0.1.0

- Initial release: HTTP/2 caller/responder transports and `RpcHttp2Server` for rpc_dart.
