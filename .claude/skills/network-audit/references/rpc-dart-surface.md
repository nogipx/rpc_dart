# rpc_dart: where the attack surface is

A starting map for `surface` mode and for locating the code a catalog entry
names. It names symbols, not line numbers. Confirm each one with dart-runner
(`find_symbol`, `outline`, `format: "compact"`) before relying on it. If a
symbol is gone, the map is stale. Fix the map; do not guess.

## Entry points by package, in priority order

| Package | Server side (hostile client) | Caller side (hostile server) | Underlying parser |
| --- | --- | --- | --- |
| `rpc_dart_websocket` | `RpcWebSocketServer`, `RpcWebSocketResponderTransport`; upgrade in `websocket_io_connections.dart` and `websocket_bounded_upgrade.dart` | `RpcWebSocketCallerTransport`, `ws_open_io.dart`, `ws_open_stub.dart` (web) | dart:io `WebSocket` / `WebSocketTransformer`; browser `WebSocket` on web |
| `rpc_dart` core | `RpcChannelTransport`, `RpcFrameMultiplexedChannel`, `RpcDirectMultiplexedChannel`, `flow_controller.dart`, `stream_buffer_ledger.dart` | `RpcClientConnection`, the same channels | `RpcMessageParser` (`core/parser.dart`), `channel_frame.dart`, `codec/special_cbor.dart`, `RpcMetadata` (`core/metadata.dart`) |
| `rpc_dart_isolate` | the isolate and web-worker endpoints under `lib/` | the same, mirrored | `SendPort` / `postMessage` structured clone |
| `rpc_dart_wasm` | `RpcWasmTransport`, `RpcFlutterWasmBridge` | the same | the native bridge: Swift and Kotlin, which are separate code |
| `rpc_dart_http` (HTTP/1.1, unary) | `RpcHttpServer`, `RpcHttpResponderTransport`, `RpcHttpCorsPolicy` | `RpcHttpCallerTransport` | dart:io `HttpServer` / `HttpClient` |
| `rpc_dart_http2` (low priority) | `RpcHttp2Server`, `RpcHttp2ResponderTransport` | `RpcHttp2CallerTransport` | `package:http2` |

The in-memory transport (`in_memory_transport.dart`) has no hostile peer. Its
risks are aliasing and ordering (KV-MP-05).

## Limits that already exist

All live in `RpcSecurityPolicy` (`core/security_policy.dart`). Read each
field's dartdoc: it says what unit it counts and where it is charged.

- Size: `maxMessageLengthBytes`, `maxBufferedBytes`, `maxMessagesPerChunk`
- Streams: `maxActiveStreams`, `maxConcurrentHandlers`,
  `maxBufferedMessagesPerStream`
- Metadata: `maxMetadataBytes`, `maxHeaders`, `maxHeaderNameBytes`,
  `maxHeaderValueBytes`, `maxMethodPathLength`
- Time: `halfOpenStreamTimeout`
- Flow control: `flowControlWindowBytes`, `flowControlConnectionWindowBytes`,
  `initialSendWindowBytes`, `initialSendWindowGrace`
- Behaviour: `closeOnProtocolError`, `contentTypeValidation`

Other guards to know about:

- The CBOR depth guard: `_maxDepth` and `_checkDepth` in `special_cbor.dart`.
- Peer deadlines: `RpcMetadata.parseGrpcTimeout`, and `core/long_timer.dart`
  for values longer than a `Timer` can hold.
- Method paths: `parseRpcMethodPath`, `kDefaultMaxMethodPathLength`.
- Decompression: the decompressed-size checks in `parser.dart` and
  `compression_gzip_io.dart`.
- WebSocket handshake: `allowedOrigins` and `allowUpgrade`. Compression is
  `CompressionOptions.compressionOff` by default on the server; the caller's
  `enableCompression` is opt-in.
- Retries: `RpcRetryInterceptor`, `backoff_policy.dart`, and
  `circuit_breaker_interceptor.dart` and `rate_limiter.dart` in
  `resilience/`.

The existence of a limit is not a pass. For each one, the question is where
it is checked relative to where the bytes become resident (methods.md §2),
and whether it applies on every transport (RPC-08).

## Tests to extend, not duplicate

- `packages/core/rpc_dart/test/fuzz/peer_bytes_decoders_fuzz_test.dart`:
  byte-level decoder fuzzing.
- `packages/core/rpc_dart/test/fuzz/hostile_peer_and_chaos_test.dart`: a
  hostile peer and chaos against the core.
- `packages/transport/rpc_dart_websocket/test/hostile_sockets_fuzz_test.dart`:
  hostile raw sockets against the WebSocket server.
- `packages/transport/rpc_dart_websocket/test/`: many single-behaviour
  regression tests, named for the behaviour (ping flood, ghost stream ids,
  half-open keepalive, compression off by default, unfinished messages
  bounded). List the directory before writing a new one: the behaviour may
  already have a test.
- `packages/core/rpc_dart/test/transports/flow_controller_logging_test.dart`:
  the model for testing the log guard and the warn-once rule.

## What the gate does not cover

- `rpc_dart_wasm` tests run separately (`melos run test:wasm`), and its
  native code runs only under `melos run test:wasm:device`, on both
  platforms.
- `rpc_dart_generator`'s tests cannot run inside the workspace (see
  CLAUDE.md).
- The web runtime: `melos run test:web`.
- No conformance suite (Autobahn, h2spec, the gRPC interop cases) is part of
  the gate. A conformance run is a probe, and its result goes into the
  journal.

## Journal lenses that match catalog areas

Use these with `loop.py find --lens <id>`, or read them through `loop.py
next`.

| Area | Lenses |
| --- | --- |
| Limits and buffering | RPC-17, RPC-18, RPC-27, RPC-05, RPC-01 |
| Refusal paths | RPC-02, RPC-22 |
| Lifecycle | RPC-16, RPC-19, RPC-20, RPC-21, RPC-28 |
| Timeouts and cancellation | RPC-09, RPC-12, RPC-14 |
| Errors | RPC-13 |
| Ids and reconnect | RPC-03 |
| Parity across transports | RPC-04, RPC-08, RPC-10, RPC-25 |
| Runtimes and packaging | RPC-06, RPC-07, RPC-11, RPC-26 |
