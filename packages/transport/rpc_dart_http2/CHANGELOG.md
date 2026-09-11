<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 0.3.0

The largest release this transport has had. It is the one a gRPC deployment
actually exposes, and most of what follows is what an unauthenticated peer could
do to a server before it.

### Breaking

- **The HTTP/2 wire machinery is no longer exported.** Frame, stream and
  connection internals were public by omission; the transports, the server and
  the policy types are the supported surface.
- **`pingInterval` defaults to 30s** on the server. A peer that completes the
  handshake and then goes silent used to hold its connection, endpoint and
  contracts forever. Set it to null for the old behaviour.
- **Requires rpc_dart 6.** See its changelog — notably that a handler's bare
  `Exception` text no longer reaches the caller, `closeOnProtocolError` now
  defaults to false, and unary honours `RpcDataTransferMode`.

### Security

- **A peer that only sends violating frames is bounded.** `_validateInbound`
  ported the half that had a name (`closeOnProtocolError`) and not the
  256-violation backstop beside it: at the default policy, 2000 violating header
  blocks were all accepted, the connection stayed open, and RSS rose 27 MiB. The
  responder now closes on the flag or the backstop, the caller on the backstop
  alone — because killing a client's connection over one peer fault takes its
  other in-flight calls with it, and 256 times is no longer one bad frame.
- **Outbound metadata is checked against the security policy.** Only inbound was
  checked, so under `maxHeaders: 32, maxHeaderValueBytes: 64` this side happily
  sent 64 headers, a 200-character value and a header name containing a space —
  all of which the shared layer refuses.
- **The peer's header block is bounded before it is converted**, on the caller
  as well as the responder. This is the CONTINUATION flood: HTTP/2 exempts
  HEADERS from flow control, so the only bound is on size.
- **A socket that never sends the HTTP/2 preface is dropped** (`prefaceTimeout`).
  A TCP SYN used to build a transport, an endpoint and the application's
  contracts before a byte arrived: 200 silent sockets gave 200 endpoints.
- **The CONNECT-proxy handshake is bounded in time and memory.**
- **`maxActiveStreams` is honoured on the caller**, and the advertised
  `SETTINGS_MAX_CONCURRENT_STREAMS` now matches what the server enforces,
  clamped to what the field can carry.
- **gRPC is POST-only**; the server used to execute a handler for any method.
- **A request the policy rejects is answered**, not dropped — and the refusal now
  survives its own policy: under `maxHeaders: 1` the trailer carrying both
  `grpc-status` and `grpc-message` could not be sent, and the peer was told
  "Response ended without a gRPC status" (UNAVAILABLE, which reads as retryable)
  for a deterministic rejection it must never retry. The status survives and the
  message gives way.

### Fixed

- **Per-connection endpoints are closed when their connection ends.** One
  `RpcResponderEndpoint` is created per socket and none were ever released.
- **Cancelled streams are aborted with RST_STREAM**, the primitive HTTP/2 has
  for it, instead of a metadata frame that is illegal once this side has
  half-closed — and a peer's RST_STREAM is now delivered, so a cancelled call
  actually stops.
- **Backpressure works in both directions.** The caller no longer buffers its
  whole request for a stalled peer, an upload into a handler that is not
  consuming is throttled, and a slow reader genuinely slows the server down.
  A call that stalls is refused rather than pausing the connection's read loop,
  which would have stalled every other stream on it.
- **A stream ended on DATA without trailers is not a clean end**, and a
  truncated response stream is no longer reported as complete.
- **Graceful shutdown**: opt-in drain on `stop()`, GOAWAY sent when draining,
  and receiving one no longer kills in-flight calls. `close()` no longer waits
  for streams it has already doomed. A draining connection is reported as
  draining rather than saturated, and one at MAX_CONCURRENT_STREAMS as
  saturated rather than dead.
- **Keepalive on both halves** (caller and server PING), which is the only way
  to reclaim a half-open path.
- **Reconnect**: usable more than once, no longer orphans a connection per
  concurrent attempt, does not un-close a closed transport, and no longer
  restarts the stream-id sequence — a fresh id sequence after a reconnect reuses
  ids the peer still has state for.
- **Status mapping**: a peer RST_STREAM and a drained connection surface gRPC
  statuses instead of `StateError` and a raw transport exception; a non-200
  `:status` maps through the gRPC table; a 200 whose content-type is not gRPC is
  rejected; an over-limit request is answered `RESOURCE_EXHAUSTED`.
- **A transport wrapper no longer drops the security policy**, and a decorator
  that declares a capability can no longer switch the upload bound off.
- **The endpoint is released when `onEndpointCreated` throws.**
- **The caller no longer kills its own connection after four calls.**
- **Nagle is off on every socket**, as gRPC does.

## 0.2.4

- BUG (non-ASCII regular header values were silently corrupted): `_headerValue`
  base64url-encoded any non-ASCII value on send but the decode side never
  reversed it, so the peer received a mangled string (the same asymmetry class
  as the `-bin` bug). Per the gRPC HTTP/2 spec, ASCII metadata values must be
  printable ASCII (`%x20-%x7E`); a non-conforming value is now rejected with an
  `ArgumentError` instead of silently transformed. Binary or non-ASCII data must
  use a `-bin` key (base64). This also rejects CR/LF in values, closing a header
  injection vector. Tests in `test/grpc_wire_compliance_test.dart`.
  (`grpc-message` is unaffected — the core layer percent-encodes it to ASCII
  before it reaches the transport.)

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
