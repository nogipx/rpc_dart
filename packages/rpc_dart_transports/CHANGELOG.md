## 1.5.0

- **Feature**: Added HTTP/1.1 transports for unary-only fallbacks, including caller/responder/server helpers with SHA256 `x-rpc-integrity` headers and a guard that rejects non-unary methods with `UNIMPLEMENTED` (`lib/src/transports/http/rpc_http1_caller_transport.dart:1`, `lib/src/transports/http/rpc_http1_responder_transport.dart:1`, `lib/src/transports/http/rpc_http1_server.dart:1`).
- **Testing**: Added regression coverage for large payloads and verified that streaming calls receive the expected error (`test/http1_rpc_integration_test.dart:34`, `test/http1_rpc_integration_test.dart:70`).

## Unreleased

## 1.4.2

- **Security**: Guard `SecureTransportAdapter` pre-handshake buffering with a
  configurable byte cap so oversized floods can't exhaust process memory
  before a secure session is established.

## 1.4.1

- **Improvement**: `SecureTransportAdapter` can bootstrap mutual trust even
  when `peerPublicKey` isn't preconfigured; peers now advertise their
  Licensify public keys during the handshake and validate mismatches to keep
  the exchange authenticated.

## 1.4.0

- Remove dependency on io, compiles with web

## 1.3.0

- **Breaking**: Removed the `RpcServerBootstrap` production facade and bundled
  service scripts; the package now exports only the shared server interfaces,
  so integrate your own daemon/CLI layer when upgrading.
- **Feature**: Added the Licensify-backed `SecureTransportAdapter` that wraps
  any `IRpcTransport` with mutual handshake tokens, metadata sealing, optional
  padding and handshake flood protection (`lib/src/transports/secure/secure_transport_adapter.dart:33`).
- **Feature**: Shipped a TURN relay stack with an RFC 8656–compliant server,
  client transports and the `RpcTurnRelayPeer` helper for discovery-driven
  rendezvous (`lib/src/transports/relay/rfc_relay/turn_relay_server.dart:19`,
  `lib/src/transports/relay/rpc_turn_relay_transport.dart:13`,
  `lib/src/transports/relay/rpc_turn_relay_peer.dart:6`).
- **Improvement**: HTTP/2 transports can now be wrapped (e.g. with the secure
  overlay) and guard against double gRPC framing while Base64-encoding
  non-ASCII headers so handshake tokens propagate correctly
  (`lib/src/transports/http2/rpc_http2_server.dart:26`,
  `lib/src/transports/http2/rpc_http2_common.dart:40`,
  `lib/src/transports/http2/rpc_http2_caller_transport.dart:225`).
- **Quality**: Added a secure transport example plus extensive tests that cover
  handshake failure modes, TURN routing paths and WebSocket integration
  (`example/transports/secure_adapter_example.dart:1`,
  `test/secure_transport_adapter_handshake_protection_test.dart:1`,
  `test/relay/turn_relay_server_test.dart:1`).

## 1.2.0

- Implemented rich `health()`/`reconnect()` diagnostics for HTTP/2,
  WebSocket and isolate transports, exposing connection metadata and
  supported flags for automation.
- Introduced `WebSocketReconnectManager` with configurable backoff
  strategies and automatic listener re-registration to stabilize client
  reconnections.
- Fixed isolate transport shutdown and health reporting so both host and
  worker isolates surface accurate closed/degraded statuses.
- Updated documentation and examples with diagnostics guidance for
  transport consumers.

## 1.1.2
- fix: websocket connection in flutter web

## 1.1.1
- fix: web io import - remove websocket transport

## 1.1.0

- web: add universal io support to use on web

## 1.0.1

- deps: update rpc_dart

## 1.0.0

- Docs: simplify everything

## 0.1.0

- Initial version.
