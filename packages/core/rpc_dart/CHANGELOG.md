## 3.4.0

**Behavioral changes:**
- `RpcRetryInterceptor` default retry predicate is now conservative and gRPC-aligned. **BEHAVIORAL:** when no explicit `retryOn` is provided, retries happen ONLY on clearly-transient errors -- `RpcStatusException` with status `UNAVAILABLE (14)` or `RESOURCE_EXHAUSTED (8)` (the connection/transport-closed and overload signals the framework surfaces on the wire, e.g. a dropped connection becomes `UNAVAILABLE` "No response received"), plus the local `RpcRateLimitException`. Previously the default retried EVERY error except cancellation/deadline, which re-issued non-idempotent unary calls (e.g. a write that committed server-side but lost its response), causing duplicate side effects. Generic `RpcException`, `INTERNAL`/`INVALID_*` status codes, and non-RPC exceptions are no longer retried by default. An explicit `retryOn` still fully overrides the default.
- `RpcContextUtils.generateTraceId()` now generates a real unique random id (`Random.secure()` with a seeded fallback), format `trace_<base64url-16-bytes>`. **BEHAVIORAL (format):** previously the id was a deterministic pure function of the millisecond timestamp (`timestamp * 31 + 17`), so two trace ids generated in the same millisecond were IDENTICAL -- corrupting distributed-trace correlation under concurrency. The `trace_` prefix is preserved; the old `trace_<timestamp>_<n>` shape is gone.

**Security / robustness:**
- CBOR decoder now bounds container nesting depth (`_maxDepth = 256`). A crafted deeply-nested array/map/tag payload previously recursed without limit and could trigger a `StackOverflowError` (DoS from untrusted bytes); the decoder now throws `FormatException('CBOR nesting too deep')` instead. Applies to arrays, maps and tag chains on both the `decode` and `decodeUnsafe` paths. All existing CBOR + parity tests stay green on VM and `-p node`.
- Receive-path frame hardening (untrusted peer). `RpcChannelFrame.decode`/`decodeAll` and `RpcFrameMultiplexedChannel` now bound the RECEIVE/decode path against a hostile peer, sourcing limits from the `RpcSecurityPolicy` already carried by `RpcChannelTransport` (threaded into the frame channel via `RpcChannelTransport.fromChannel`/`pair`). Previously the policy was consulted only on the SEND side and the decode path trusted the declared frame length. Three fixes:
  - **Remote OOM:** a frame header declaring an oversized payload (`payloadLen` up to 4 GiB) is now rejected from the header alone -- the oversized payload is never sliced or buffered. `decodeAll`/`decode` take an optional `maxPayloadLen` and throw the new typed `RpcFrameException` when the declared length exceeds `RpcSecurityPolicy.maxMessageLengthBytes`. The frame channel also caps the reassembly buffer at `RpcSecurityPolicy.effectiveMaxBufferedBytes`, so a peer dribbling bytes toward a huge declared frame is stopped before unbounded buffering. On violation the channel surfaces `RpcFrameException` on the incoming stream and closes.
  - **Receive-loop crash on malformed metadata:** `_decodeMetadataPayload` previously did unchecked casts on attacker JSON (`as Map<String,dynamic>`, `map['p'] as String?`, `h[0]/h[1] as String`), so a top-level array, malformed JSON, invalid UTF-8, or non-string header values threw `TypeError`/`FormatException` synchronously out of the listen callback as an unhandled async error. Decoding is now fully defensive: UTF-8, JSON object shape, methodPath type, and each header entry (a list of exactly two strings) are validated, yielding a typed handled `RpcFrameException` surfaced via the incoming stream instead of an uncaught throw into the zone.
  - **Decompression bomb:** the built-in `dart:io` gzip fallback now decodes in a chunked manner and aborts as soon as the accumulated output would exceed the policy limit, instead of fully materializing the expansion before the post-decompress size check. `RpcCompressionCodec.decompress`, `RpcGrpcCompression.decompress`, and the parser's `decompressor` hook gained an optional `maxOutputBytes`; `RpcMessageParser` passes its `maxMessageLength` so a tiny gzip bomb is rejected with a `FormatException` before full expansion. The existing post-decompress backstop check remains for codecs that ignore the hint. New regression tests cover all three on VM, with the frame/metadata cases also green on `-p node`.

**Fixes:**
- `RpcCircuitBreakerInterceptor` reset-timeout timing now uses a monotonic `Stopwatch` instead of `DateTime.now()` subtraction. A backward wall-clock jump (NTP correction, manual clock change) previously made the elapsed-since-last-failure go negative or huge, so the breaker could either never half-open or half-open instantly. Behavior under a normal clock is unchanged (covered by the existing resetTimeout half-open tests). The class does not expose a clock injection seam, so the monotonic source is internal.

## 3.3.1

- `RpcClientConnection.forceReconnect()` now resets the attempt counter and resumes even after `disconnect()` -- previously it could leave the connection stuck in `Offline` (the reconnect loop exited immediately because `_isStopped` was still set) or inherit a stale attempt count and hit `maxAttempts` early. Documented that in-flight calls do not survive a reconnect (only the endpoint and new calls do) and that `maxAttempts` counts from the initial drop. Added regression tests.
- Removed the `rpc_dart_compression` dev-dependency. The compression negotiation test now registers a small test-local reversible codec under the `gzip` encoding instead of pulling in `RpcGzipCodec`, so the published package has no path dependency. No runtime/API change.

## 3.3.0

**Features / changes:**
- `RpcRateLimiter` now does PER-MESSAGE accounting on streaming RPCs. **Potentially behavioral:** previously a streaming call consumed a single token at stream open regardless of message count; the default is now that EVERY message on the message-bearing direction (server-stream responses, client-stream/bidi requests) counts against the limit. On mid-stream exhaustion the wrapped stream emits an `RpcRateLimitException` error (gRPC RESOURCE_EXHAUSTED) instead of silently dropping. Unary behavior is unchanged.
- `RpcCircuitBreakerInterceptor` half-open is now single-probe: exactly ONE probe is admitted in `halfOpen`; concurrent calls are rejected with `CircuitBreakerOpenException` until the probe resolves (success -> close, failure -> reopen). Previously every call was allowed through in `halfOpen`, flooding a recovering service.
- CBOR decoder now handles CBOR tags (skips tag, reads tagged value) and the `undefined` simple value (maps to `null`). Previously these threw `FormatException` on the production `CborCodec.decode` path.
- CBOR robustness: the decoder now also decodes indefinite-length arrays, maps, text strings and byte strings; IEEE 754 half (16-bit) and single (32-bit) floats; and extended one-byte simple values.
- CBOR readers/writers unified: the redundant slow reference reader (`_CborReader`) and the static `_encode*` writer family were removed. `CborCodec.decodeUnsafe` now decodes via the single fast reader (`_FastCborReader.readValue`, any top-level value to dynamic) and `CborCodec.encodeUnsafe` now encodes via the single fast writer (`_FastCborWriter.writeValue`, arbitrary top-level values with lax map keys). Return types and byte output are unchanged: nested maps remain `Map<String, dynamic>`, arrays `List<dynamic>`, byte strings `Uint8List`; `encode`/`encodeUnsafe` stay byte-compatible (guarded by the parity test). This removes the prior risk of the two readers/writers silently diverging.
- CBOR encoder hardening on dart2js: a non-finite double (`Infinity`/`-Infinity`/`NaN`) classified as an `int` under JavaScript's single number type is now encoded as an IEEE 754 double instead of crashing in the 64-bit integer writer (`Result of truncating division is Infinity`). `_writeUint64BigEndian` also throws a clear `FormatException` if a non-finite value ever reaches it. Additionally, a finite integer-valued double of magnitude `>= 2^64` (e.g. `1e300`) also reports `is int` under JavaScript and previously overflowed the integer encoder, silently decoding back to `0`; such values are now encoded as IEEE 754 doubles and round-trip correctly. Native-VM `int`s (bounded by int64) are unaffected.
- Added `test/serializers/cbor_parity_test.dart`, a corpus-based decode/round-trip guard (int boundaries incl. `>2^32`/`>2^53`/negatives, doubles incl. `NaN`/`Infinity`/`-0.0`, unicode/empty strings, empty/non-empty byte arrays, tags, indefinite lengths, deep nesting). Runs on VM and `-p node`. After the reader/writer unification it asserts that `encode(x)` round-trips through `decode`, that `decode` and `decodeUnsafe` agree, that `encode` and `encodeUnsafe` are byte-identical, and that hand-crafted exotic CBOR decodes to expected values.
- The "Unsupported grpc-encoding" error (caller, responder pipeline, and the compression registry) now hints at the fix: on web/dart2js the built-in dart:io gzip is unavailable, so register a cross-platform codec (e.g. `RpcGzipCodec.register()` from `package:rpc_dart_compression`). Message text only; behavior unchanged.
- `test/streams/compression_test.dart` now registers `RpcGzipCodec` (added `rpc_dart_compression` as a dev-dependency) so the gzip server-stream/client-stream/bidi roundtrip tests exercise compression cross-platform and pass identically on VM and `-p node`/`-p chrome`, instead of relying on the VM-only built-in gzip.
- Fixed a dart2js (`-p node`/`-p chrome`) hang when cancelling a long-lived server-stream subscription on the caller side. `RpcCallerEndpoint.serverStream` previously returned `() async* { yield* stream }()` over a chain of suspended `async*`/`await for` generators (`handleServerStream` -> response middleware -> `ServerStreamCaller.call`). On dart2js, `await sub.cancel()` against that chain — while the server stream was still open (e.g. gRPC Health `Watch`) — never resolved, so the cancel deadlocked and any caller awaiting it timed out. The caller-facing stream is now bridged through an explicit `StreamController` whose `onCancel` releases request tracking and fires the inner cancel without awaiting it, making cancellation deterministic and identical on VM and dart2js. Server-stream emission, ordering, and resource cleanup are unchanged; VM and `-p node` now both pass the `grpc_health` `Watch` tests.

## 3.2.3

**Fixes (audit):**
- CBOR 8-byte integer READ was truncated on dart2js (`(result << 8)` uses 32-bit JS bitops) -- now reads hi/lo 32-bit halves and recombines, mirroring the write-side fix. Values above 2^32 now round-trip correctly in the browser.
- Circuit breaker was a no-op for streaming RPCs: it recorded success as soon as the `Stream` object was returned. Errors emitted during stream production now count as failures; an open circuit on a stream RPC surfaces as a stream error instead of a synchronous throw.
- `TransportRouter` leaked the subscription, stream maps and server stream id when `sendMetadata` threw -- failed sends now roll back all state.
- `error_details` decoding now validates length-delimited bounds and bounds the varint loop, throwing `FormatException` on malformed input instead of an uncaught `RangeError`.
- `ResponderPipeline` no longer creates per-stream state for junk control frames (unbounded-memory vector); `drain()` now actually closes the remaining streams on timeout instead of only logging.
- `RpcRateLimiter` no longer repopulates its counters after `dispose()` (added `_disposed` guard) and accepts an injectable monotonic clock via `nowMicros` (default monotonic, no longer wall-clock sensitive).

**Behavioral changes:**
- `RpcNum`/`RpcInt`/`RpcDouble.operator ==` no longer throws for a non-`RpcNum` operand -- it returns `false` per the Dart `==` contract.
- `RpcNum.fromJson`/`RpcInt.fromJson`/`RpcDouble.fromJson` now throw `FormatException` on malformed input instead of silently returning `0`.

## 3.2.2

**Fixes:**
- Fixed CBOR encoder using `ByteData.setUint64` which is unsupported in dart2js -- replaced with JS-safe 32-bit writes
- Removed applied RPC log types (`RpcLogOutput`, `RpcLogResponder`, `RpcLogServiceResponder`, `RpcLogServiceCaller`) -- moved to `rpc_dart_log` package

**Logger stabilization:**
- Added `LogOutput.writeAsync()` and `isAsync` for async output backends (database, HTTP)
- Added `LogController.addEnricher()` / `removeEnricher()` / `setRedactor()` for runtime pipeline management
- Added `LogController(clock:)` for deterministic timestamps in tests -- propagated through `LogScope` and `LogSpanHandle`

## 3.2.1

**Fixes:**
- Fixed `LogController.add()` redundant enricher condition that was always true
- Fixed `LogRedactor` not redacting error messages and log message text -- now matches `field=value` / `field:value` patterns in strings
- Fixed `ConsoleOutput` JSON key escaping -- keys containing `"`, `\`, newlines are now properly escaped
- Fixed `RingBufferOutput` using fake `LogEvent` placeholder -- replaced with nullable list
- Fixed `RpcLogOutput.flush()` silently swallowing send errors -- added `droppedCount` counter
- Removed dead `noSuchMethod` override from noop span handle
- Added `RpcResponderEndpoint.setLogController()` for post-construction logger injection

## 3.2.0

**Built-in logging system:**
- New `LogController` / `LogScope` architecture replaces old `RpcLogger`
- Pipeline: level filter -> sampling -> enrichers -> redaction -> outputs
- `LogScope.noop` for zero-cost disable when no logger configured
- `sealed LogRecord` with three types: `LogSpanStart`, `LogEvent`, `LogSpan`
- Endpoints accept `LogController? logger` parameter

**Spans (operations with duration):**
- `withSpan()` / `startSpan()` API for measuring operation timing
- Spans bypass level filter (telemetry, not logs) — available in production even with `minLevel = fatal`
- `spansEnabled` flag for opt-out
- Span ID (6 hex chars) links events to their span in console output

**Console output (logfmt-style):**
- One line per record, structured key=value fields
- Three formats: `pretty` (colored), `json`, `compact`
- traceId shown automatically when present
- Span start (`>>`), events, and span end with duration on separate lines

**Responder auto-logging:**
- `context.log` in responder handlers auto-configured with scope, traceId, requestId
- Scope includes service and method name: `rpc.{endpoint}.{Service}.{method}`
- Works for all stream types (unary, server, client, bidirectional)

**Production features:**
- `SamplingConfig` — per-level rate limiting
- `LogEnricher` — auto-attach fields (host, pid, etc.) to every record
- `LogRedactor` — strip sensitive fields (password, token) from data
- `RingBufferOutput` — in-memory history, queryable by `LogFilter`

**RPC log transport:**
- `RpcLogOutput` — send logs to remote peer with offline buffer
- `RpcLogResponder` — accept remote logs into local controller
- `RpcLogServiceResponder` — expose subscribe stream + history + remote control
- `RpcLogServiceCaller` — client API for remote diagnostics

**Breaking:**
- Removed `RpcLogger`, `RpcLoggerColors`, `AnsiColor`, `RpcLoggerLevel`, `RpcContextAwareLogger`, `RpcContextualLogging`
- Removed extension methods: `logRpcError`, `logRpcWarning`, `logStreamBound`, `logStreamFinished`, `logMessageReceived`
- Endpoint constructors: `loggerColors` parameter removed, `logger` parameter now takes `LogController?`

## 3.1.1

**Bug fix:**
- Fixed `Uint8List` CBOR encoding on dart2js: added `TypedData` fallback in `_FastCborWriter` and `_encodeValue` to ensure typed byte arrays are always encoded as CBOR byte strings (major type 2), not integer arrays (major type 4). Without this fix, blob uploads from dart2js clients produced ~1.9x inflated byte counts on the server, causing "declared length does not match received bytes" errors.

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
