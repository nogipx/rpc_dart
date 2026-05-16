## 3.1.0

**Structured error model:**
- `RpcStatusException` now carries typed `details` list — structured error information sent via `grpc-status-details-bin` trailer (wire-compatible with standard gRPC `google.rpc.Status`).
- Added `RpcErrorDetail` hierarchy: `RpcBadRequest` (field violations), `RpcRetryInfo` (retry delay), `RpcDebugInfo` (stack traces), `RpcErrorInfo` (reason/domain/metadata), `RpcRawErrorDetail` (unknown types passthrough).
- `RpcStatusException.fromTrailer()` factory reconstructs typed exceptions from wire data on the caller side.
- All four caller patterns (unary, server-stream, client-stream, bidirectional) now throw `RpcStatusException` instead of generic `Exception` on gRPC errors.
- All responder patterns forward `statusDetailsBin` in error trailers when handler throws `RpcStatusException` with details.
- Minimal protobuf encoding/decoding for `google.rpc.Status` and `google.protobuf.Any` — no external protobuf dependency.

**Graceful drain:**
- Added `RpcResponderEndpoint.drain({Duration timeout})` — initiates graceful shutdown: rejects new streams with `UNAVAILABLE`, cancels active stream contexts via cancellation token, waits for completion.
- Responder pipeline now attaches `RpcCancellationToken` to all incoming stream contexts automatically — handlers can listen for cancellation during shutdown.
- `RpcApp._drainEndpoints()` (framework) now calls `endpoint.drain()` in parallel instead of polling.

**Other:**
- Added `RpcPeerContract` — base class for bidirectional contracts where either side can initiate calls. Extends `RpcResponderContract` and exposes `callUnary`, `callServerStream`, `callClientStream`, `callBidirectionalStream` methods bound to the same `RpcPeerEndpoint`.
- `RpcPeerEndpoint` is now exported from the library public API.
- `RpcServiceKind` enum added to `annotations.dart` (`unidirectional` / `peer`) for use with `@RpcService(kind: ...)`.
- `@RpcService` gained `grpcDescriptor` flag (default `false`) — when `true`, the generator emits a `grpcDescriptor` static field for gRPC Server Reflection registration.
- `RpcContextUtils.generateTraceId()` is now public (was `_generateTraceId`).
- `RpcResponderContract.serviceName` supports dynamic suffix via `serviceNameSuffix` setter — used for scoped/isolated service registrations.
- Internal refactor: `caller_pipeline.dart` and `responder_pipeline.dart` extracted as separate part files; logic unchanged.

## 3.0.1

- `RpcMessageParser`: replaced `List<int>` backing buffer with `Uint8List` — eliminates integer boxing and reduces message extraction from two copies to one.
- `special_cbor.dart`: fixed JS-unsafe 64-bit integer encoding — replaced `>> 56` / `>> 48` / ... bit-shift chains with `ByteData.setUint64`, which is correctly implemented on both Dart VM and dart2js.
- `RpcContext.withAdditionalHeaders`: removed duplicate `_sanitizeHeaders` call that could silently drop headers when the merged map exceeded the 128-header or 64 KB limit.
- `RpcCallerEndpoint`: changed `compressionEnabled` default from `true` to `false` to avoid compatibility issues with servers that do not advertise compression support.
- Removed CORD-specific API (`createChain`, `forBusinessOperation`, `forDomainCall`, `extractDomainMetadata`, `DomainMetadata`, `RpcContextAware`, `correlationId`).

## 3.0.0

Breaking changes and major additions:

**3-layer transport architecture** (`IRpcChannel` / `IRpcMultiplexedChannel` / `RpcChannelTransport`):
- `IRpcChannel` — minimal raw byte pipe interface
- `IRpcMultiplexedChannel` — multiplexed message channel between channel and transport
- `RpcFrameMultiplexedChannel` — wraps `IRpcChannel` with 9-byte frame codec
- `RpcDirectMultiplexedChannel` — zero-copy in-memory paired channel
- `RpcChannelTransport` — `IRpcTransport` wrapper with `.pair()`, `.memoryPair()`, `.fromChannel()` factories
- `RpcInMemoryTransport.pair()` is now a thin delegate to `RpcChannelTransport.memoryPair()`

**Resilience primitives** (moved from `rpc_dart_framework` to core):
- `RpcRetryInterceptor` — configurable retry with `BackoffPolicy` (constant, linear, exponential)
- `RpcCircuitBreakerInterceptor` — circuit breaker with open/half-open/closed states
- `RpcClientConnection` — reconnect state machine with health monitoring
- `RpcRateLimiter` — pluggable rate limiting with per-key dynamic limits

**gRPC Health Checking Protocol**:
- `RpcGrpcHealthService` — implements `grpc.health.v1.Health` (`Check` + `Watch`)
- `RpcGrpcHealthClient` — typed client for health checks

**Other**:
- `RpcBinaryCodec<T>` now works with any `T extends Object` (not just `IRpcSerializable`)
- `RpcStatusException(statusCode, message)` — handlers can return specific gRPC status codes
- `dart:typed_data` re-exported via `rpc_dart.dart` (`Uint8List` available without extra import)
- Removed `onServiceRegistered` callback from `RpcResponderEndpoint`

## 2.6.3

- Added `RpcRemoved` annotation. Marks an inherited RPC method as removed in a versioned contract. The generator produces a `@Deprecated` + `throw UnsupportedError` implementation so callers receive a compile-time warning and a clear runtime error message.

## 2.6.2

- `RpcMessageParser`: replaced per-message buffer slicing with a read-offset approach — `advance()` moves a pointer in O(1) and a single `compact()` at the end of each parse pass drops consumed bytes in O(remaining), eliminating the previous O(N²) copy behaviour when multiple gRPC frames arrive in a single chunk (relevant for HTTP/2 and WebSocket transports).
- `RpcMessageParser`: fixed a latent bug where the loop condition `buffer.length >= 5` prevented re-entry after a 5-byte header arrived without a body shorter than 5 bytes, causing such messages to stall in the buffer indefinitely.

## 2.6.1

- `IRpcServer`: removed `host` and `port` from the interface — these are transport-level concerns, not RPC server concerns.
- `IRpcServerFactory` interface removed along with `RpcHttp2ServerFactory` and `RpcWebSocketServerFactory` — the abstraction had no consumers.

## 2.6.0

- Added `RpcHeaders` class with gRPC semantic header name constants; all internal
  metadata and protocol code now uses `RpcHeaders.*` instead of raw strings.
- Core parser passes compressed frames through when no decompressor is configured
  so the application layer (transport) can handle decompression — core stays agnostic.
- Transport packages now own their own wire-format: pseudo-headers (`:method`,
  `:path`, `:status`, etc.) are generated by each transport and never stored in
  `RpcMetadata`; `http2HeadersToRpcMetadata` filters them out automatically.
- `RpcHttpCorsPolicy`: always exposes `grpc-encoding`, `grpc-status`,
  `grpc-message`, `grpc-accept-encoding` in `Access-Control-Expose-Headers` so
  browsers do not block them in cross-origin responses.
- `RpcHttpCorsPolicy`: always allows `grpc-timeout`, `grpc-encoding`,
  `grpc-accept-encoding` in `Access-Control-Allow-Headers`.
- `RpcHttpCorsPolicy`: `exposedHeaders` parameter renamed to `extraExposedHeaders`
  to clarify it is additive on top of the required gRPC headers.
- `RpcCallerEndpoint`: injects `grpc-accept-encoding` into context based on
  `compressionEnabled` so globally-registered codecs do not force server-side
  compression when the endpoint has compression disabled.
- WebSocket transport: metadata is now encoded as binary CBOR (`WsMetadataCodec`)
  instead of JSON — ~40 % more compact, self-describing, no extra dependencies;
  wire format: `{"h":[["name","val"],...],"p":"/Svc/Method"}`.
- WebSocket transport: `_ensureGrpcFrame` normalises parser output to gRPC frames,
  consistent with HTTP/2 transport delivery to `incomingMessages`.
- Exported `CborCodec` from `rpc_dart` for use by transport packages.

## 2.5.1

- Compression is now pluggable via `RpcCompressionCodec` interface and `RpcGrpcCompression.register()`.
- Native dart:io gzip continues to auto-register on startup as before.
- External packages (e.g. `rpc_dart_compression`) can now register codecs on web/JS/Wasm.

## 2.5.0

- Added gzip compression support: `RpcCallerEndpoint` now has a `compressionEnabled` flag (default `true`) that automatically injects `grpc-encoding: gzip` for non-zero-copy transports (e.g. network transports).
- `StreamProcessor` auto-detects request/response encoding from incoming metadata (`grpc-encoding` / `grpc-accept-encoding`), enabling transparent decompression on the server side.
- `UnaryResponder` captures `grpc-accept-encoding` per stream to compress unary responses when the client advertises support.
- `RpcMetadata.forServerInitialResponse` now accepts an optional `encoding` parameter to include `grpc-encoding` in the initial server response headers for streaming compression.
- Added compression tests for all stream types (unary, server streaming, client streaming, bidirectional).
- Fix: `UnaryResponder` now captures `grpc-encoding` from incoming client metadata per stream and uses it for decompression, matching the behaviour of `StreamProcessor`.
- Fix: caller and streaming processors now validate `grpc-encoding` against supported encodings before compressing and throw `RpcException` with a clear message instead of `UnsupportedError`.
- Fix: `UnaryResponder` now throws `RpcException` (was bare `Exception`) when the request frame is empty.
- Refactor: per-stream state in `UnaryResponder` consolidated from five parallel maps into a single `_UnaryStreamState` object — cleanup is now atomic.
- Refactor: response-encoding negotiation logic extracted to `RpcGrpcCompression.selectResponseEncoding()` and reused by both `UnaryResponder` and `StreamProcessor`.
- Refactor: `RpcCallerEndpoint._effectiveContext` renamed to `_prepareContext` for clarity.

## 2.4.1

- Add interface for transport server

## 2.4.0

- Breaking: removed transport toolkit (`transport_toolkit.dart`) from the public API surface.
- Added `RpcSecurityPolicy` to centralize transport/parser limits and metadata validation.
- Security: `grpc-message` is now percent-encoded per gRPC HTTP/2 spec; added `decodeGrpcMessage` helper.
- Protocol: client request metadata now includes `grpc-accept-encoding` (advertises supported message encodings).
- Fix: clean up `RpcCallerEndpoint` cancellation token registry after completed calls (prevents memory growth in long-lived clients).
- Security: `RpcInMemoryTransport` now enforces policy limits (metadata validation, active stream cap); `pair()` accepts an optional `policy`.

## 2.3.4

- fix lints package compatibility

## 2.3.3

- fix test package compatibility

## 2.3.2

- Added annotations for codegeneration

## 2.3.1

- Optimize ping requests
- Introduced a unified middleware and interceptor pipeline across caller
  and responder endpoints, ensuring context propagation for unary and
  streaming RPC flows.
- Added `RpcMiddlewareContext` enhancements and default async hooks so
  extensions can enrich request/response handling without touching the
  core.
- Hardened serialization by validating codec decoders and shipping a
  pluggable `RpcBinaryCodec` for external binary formats such as
  protobuf.
- Expanded the test suite with exhaustive pipeline coverage for all RPC
  shapes and binary codec scenarios.

## 2.3.0

- Added aggregated diagnostics for caller and responder endpoints with
  `health()`/`reconnect()` snapshots that combine endpoint metrics and
  transport status via `RpcEndpointHealth` and `RpcHealthStatus`.
- Implemented a built-in ping protocol between endpoints that exposes
  round-trip timing, responder metadata and debug labels through
  `RpcCallerEndpoint.ping()`.
- Extended transport infrastructure with `IRpcTransport.health()` and
  `IRpcTransport.reconnect()` plus detailed implementations for
  `RpcInMemoryTransport`, `RpcTransportRouter` and the transport toolkit,
  including automatic partner shutdown to avoid close deadlocks.
- Improved `RpcStreamIdManager` so stream identifiers are recycled after
  hitting the HTTP/2 limit, preventing allocation failures during
  long-lived workloads.
- Updated documentation and examples with health monitoring guidance and
  diagnostics-driven workflows.

## 2.2.2

- Docs: simplify everything

## 2.2.1

- Fix: remove base class modifier to allow mock contracts

## 2.2.0

- Added support for cancellation in caller/responder
- Fix timeout passing through headers

## 2.1.1

- Update logo

## 2.1.0

- Added dispose base method to responder to cleanup resources

## 2.0.0

- Updated license to MIT
- Added logo to the package
- Added readme translations (RU, EN)

## 1.8.0

- Added ability to specify data transfer mode in contract (zero-copy, codec, auto)

## 1.7.0

- Added ability to specify whether transport supports Zero-Copy

## 1.6.0

- Added Zero-Copy optimization for `RpcInMemoryTransport` - object transfer without serialization/deserialization

## 1.5.0

- Added Transport Router for smart routing of RPC calls between transports
- Added typedef RpcRoutingCondition for typing routing condition functions
- Added support for routing rules with priorities (routeCall, routeWhen)
- Added conditional routing capability with access to RpcContext
- Added automatic validation of transport roles (client/server)
- Implemented correct Stream ID routing between transports
- Added router statistics and detailed logging
- Updated documentation with Transport Router usage examples
- `RpcLoggerSettings` -> `RpcLogger`
- `RpcContextPropagation` -> `RpcContext`

## 1.4.0

- Added RpcContext API with full gRPC-style context support
- Added support for headers, metadata, deadline and timeout
- Added distributed tracing support with trace ID
- Added `internal` logging level for library internal details
- Eliminated log duplication, library is "silent" by default
- Optimized InMemoryTransport for improved performance
- Fixed race conditions and deadlock situations
- Increased reliability of tests and CI/CD pipeline

## 1.3.2

- Removed auto-start of Responders
- Removed bundleId from `StreamDistributor`
- Updated documentation

## 1.3.1

- Optimized CBOR serializer and deserializer
- Added benchmarks for performance testing

## 1.3.0

- Updated documentation

## 1.2.2

- Added 1ms delay for data transfer stability

## 1.2.1

- Fixed specific errors in rpc-method operations (timeouts)

## 1.2.0

- Fixed critical bug with stream processing in Stream Processor
- Added explicit support for `bindToMessageStream()` method for manual stream binding
- Improved error handling in streams through gRPC statuses in metadata
- Fixed deadlock situations in client, server and bidirectional streams
- Optimized timeouts in tests for faster execution
- Improved documentation on working with streams and error handling
- Fixed issue with double stream listening in ClientStreamResponder

## 1.1.0

- Added `RpcStreamIdManager` for stream ID management

## 1.0.3

- CBOR serializer now works only with `Map<String, dynamic>`

## 1.0.2

- Added `StreamDistributor`
- Fixed linter issues

## 1.0.1

- Added subcontract registration
- Fixed unary method operations

## 1.0.0

- First stable release
- Implemented contract-based Backend-for-Domain (BFD) architecture
- Added support for all RPC types: unary calls, server streaming, client streaming, bidirectional streaming
- Added efficient CBOR serialization
- Added primitive types (String, Int, Double, Bool, Null) with operator support
- Implemented extensible logging system with color and level support
- Added universal transports: InMemoryTransport and IsolateTransport
- Implemented timeout handling and informative errors
- Main package contains only platform-independent transports, platform-specific ones will be available in separate packages

## 0.2.0

- Improved stream handling (BidiStream, ClientStreamingBidiStream, ServerStreamingBidiStream)
- Added support for diagnostic metrics and monitoring
- Improved marker handling in streams for more reliable interaction
- Added typed markers for various operations (stream completion, timeouts, etc.)
- Improved error handling and status transfer between client and server
- Optimized metadata handling in requests and responses
- Improved deadline and timeout handling in RPC operations
- Added operation cancellation mechanism

## 0.1.1

- Fixed error when registering contracts
- Added MsgPack serializer

## 0.1.0

- Initial release
