## 0.2.4

- BUG (`-bin` header wire format was double-encoded and corrupted true binary):
  the metadata layer already stores `-bin` values base64-encoded (e.g.
  `base64Encode(statusDetailsBin)`), but the HTTP/2 transport base64-encoded
  them AGAIN on send (`_headerValue`) and base64+utf8-decoded them on receive
  (`http2HeadersToRpcMetadata`). This double-processing was only self-consistent
  rpc_dart<->rpc_dart and broke interop with real gRPC peers in both directions;
  it also corrupted inbound binary that was valid UTF-8. `-bin` values are now
  passed through verbatim on both send and receive (they are already the base64
  string gRPC expects on the wire; the metadata getters decode on read).
  NOTE: this is a wire-format change for `grpc-status-details-bin` over HTTP/2 —
  a rpc_dart peer on <=0.2.3 will not interop with >=0.2.4 for status details.
  Regression tests in `test/grpc_wire_compliance_test.dart` (round-trips
  non-UTF8 binary).

- BUG (END_STREAM landed on the wrong message of a batch): when a single DATA
  frame parsed into multiple messages, both `RpcHttp2ResponderTransport`
  (`_handleIncomingData`) and `RpcHttp2CallerTransport` (`_handleDataMessage`)
  detected the last message via `msgData == messages.last`. `messages` is a
  `List<Uint8List>` and `==` on `Uint8List` is identity-based, so the
  end-of-stream flag could land on an earlier element (e.g. when an earlier
  element shared the same object reference as the last). END_STREAM is now
  selected positionally — only the genuinely last element of the batch
  (`i == messages.length - 1`) is marked end-of-stream. Regression test:
  `test/audit/end_of_stream_batch_test.dart`.

## 0.2.3

- BUG (silent data loss on server-initiated streams): `RpcHttp2ResponderTransport`
  sends (`sendMetadata` / `sendMessage`) now THROW a `StateError` when targeting
  a stream id that is not a known incoming (client-initiated) stream — i.e. an
  id minted by `createStream()` (server-push, unimplemented) or a stale/released
  id. Previously such sends logged a warning and returned, silently dropping the
  data. Legitimate unary/streaming responses, which reply on the client's stream
  id, are unaffected. Server-push remains unimplemented; the dead
  `_outgoingStreams` map (read but never populated) was removed along with its
  health/clear references.

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
