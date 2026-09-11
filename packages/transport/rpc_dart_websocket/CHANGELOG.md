<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

## 0.4.0

### Breaking

- **`permessage-deflate` is off by default**, on the server and in what the
  client offers. It is a decompression bomb with no output bound: 0.25 MiB
  uploaded expanded to 516 MiB of RSS (2071x), against 2.7x with it off. The
  inflation happens inside `dart:io`, which exposes no limit, so the only lever
  is not negotiating the extension. Re-enable it deliberately if both peers are
  trusted.
- **`pingInterval` defaults to 30s** on the server. A peer that completes the
  handshake and then goes silent used to hold its connection, endpoint and
  contracts forever.
- **Requires rpc_dart 6.** See its changelog — notably that a handler's bare
  `Exception` text no longer reaches the caller, and that a response ending
  without a `grpc-status` now raises `UNAVAILABLE` instead of ending cleanly.

### Security

- **A server can refuse a cross-origin handshake** (opt-in): a browser will
  happily let any page open a WebSocket to your server.
- **A duplicated `Origin` header no longer kills the server process.**
- **The drain on a refused upgrade is bounded**, so refusing a connection is
  cheaper than accepting one rather than more expensive.
- **The inbound message ceiling is pinned by a test** rather than claimed in a
  doc comment: a 64 MiB message closes the connection with 4400 and the reason
  naming the buffer overflow, three 8 MiB messages are accepted. What bounds it
  is `maxMessageLengthBytes`; the peak allocation cannot be helped, because
  `dart:io` buffers a whole message before delivering it, so what matters is
  that the connection closes — a surviving one is an unlimited supply of peaks.

### Fixed

- **A dead call's teardown acted on a live one after a reconnect**, because the
  stream id had been reused.
- **Concurrent `reconnect()` orphaned a socket per attempt.**
- **Keepalive on both halves**, which is the only way to notice a half-open
  path; neither caller noticed the peer had died.
- **Graceful drain on `stop()`** (opt-in), and the server stops accepting before
  it drains.
- **A framing violation hung up without saying so**, and a non-binary frame was
  dropped silently instead of reported.
- **The peer's close code reaches the caller as a gRPC status** instead of a
  blanket `UNAVAILABLE`.
- **`close()` deadlocked when nothing listened to `incoming`.**
- **A failed `start()` left the server claiming to run**, and a call after a
  failed reconnect killed the isolate.
- **A socket that arrives after the transport has closed is closed**, not
  leaked.
- **The endpoint is released when `onEndpointCreated` throws.**
- **The transport no longer hides its security policy from the endpoint**, and a
  throwing observability callback no longer kills the server.

## 0.3.0

### Fixed

- Per-connection endpoints are closed when their connection ends; they were
  never released, so every connection leaked one.

### Changed

- Requires rpc_dart 5. See its changelog: flow control is on by default, an
  expired deadline is now `RpcDeadlineExceededException` on every shape, and a
  stream that ends without a trailer raises `UNAVAILABLE`.

## 0.2.3

- Fixed: `RpcWebSocketCallerTransport` no longer permanently closes itself when the underlying socket drops gracefully (server-side FIN) *and* a `reconnectFactory` is configured. Previously the `onDone` cascade flipped the transport to closed, so a later `reconnect()` returned "Transport closed" — defeating reconnect after a server-initiated drop. The stable `incomingMessages` stream now survives the drop so subscribers persist and `reconnect()` can re-attach. This is the recovery path the `rpc_dart_log` client relies on. Without a `reconnectFactory` the transport still closes fully on drop (unchanged).
- Expanded test coverage of the flagship streaming transport:
  - `test/websocket_rpc_contract_test.dart`: full typed RPC contract end-to-end over a real `dart:io` WebSocket server (`RpcWebSocketServer` + `RpcResponderEndpoint`/`RpcCallerEndpoint`, ephemeral localhost port). Covers unary, server-stream (ordered delivery + completion), client-stream (aggregation), bidirectional (ordered echo), typed `RpcStatusException` propagation, mid-stream cancellation (no hang, transport stays usable), concurrent calls/streams (no cross-wiring), and a high-volume ordered stream.
  - `test/websocket_reconnect_test.dart`: reconnect coverage (previously zero). Proves `reconnect()` re-establishes the socket, the stable `incomingMessages` stream survives for pre-existing subscribers, requests issued after reconnect reach a freshly-bound server, full endpoint-level RPC recovers after a server swap, the no-factory/already-closed paths report correctly, and a regression guard for the graceful-drop fix above.

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
