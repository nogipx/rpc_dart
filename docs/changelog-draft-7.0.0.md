<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# CHANGELOG draft for the major release

A draft, not a release. Versions are the owner's to choose; the core section is
written for `rpc_dart` 7.0.0, the rest as "next version" per package. Move each
section into that package's `CHANGELOG.md` at release and cut what is not worth
a line. Source: commits since `rpc_dart-6.3.0` and the migration table in
`major-release-proposals.md`.

---

## rpc_dart 7.0.0

### Upgrade both ends together

**The channel-frame wire format changed.** Frame metadata is encoded in binary.
A 6.x peer and a 7.0 peer cannot talk over a channel transport (websocket,
socket, wasm, in-memory). Upgrade client and server in one step. HTTP/2 and
HTTP/1.1 speak gRPC on the wire and are not affected.

**Channel transports now carry a protocol version.** The client opens each
connection with an 8-byte preface, `rpcdart` and
`RpcChannelFrame.protocolVersion`, and sends its calls right behind it. The
server writes nothing until that preface arrives, then answers with the same
version. A version the other side does not speak fails every call with
`FAILED_PRECONDITION` and a message naming both versions; a peer that is not an
rpc_dart channel fails with `UNKNOWN`. Because the server answers in the
client's version, a later server can keep serving older clients. A
hand-written byte peer has to send `RpcChannelFrame.preface` before its first
frame. `RpcFrameMultiplexedChannel` takes a required `isClient`, and
`closeOnOversizedFrame` defaults from it: true for a server, false for a
client. Its `ready` completes when the peer's preface has matched, and
`prefaceTimeout` (also on `RpcChannelTransport.fromChannel`) bounds the wait.
A channel transport's `ready` includes it, so `RpcClientConnection` reports
Online only once an rpc_dart server has answered.

### Public API

**Two libraries.** `package:rpc_dart/rpc_dart.dart` is the application API.
Transport-authoring types (channels, frames, the message parser and router,
flow-control interfaces, write backlog, connection host, `RpcTrailers`) moved to
`package:rpc_dart/transport.dart`, which re-exports the first. Types that only
the library itself used are no longer exported.

**Transport capabilities are members of `IRpcTransport`**, with defaults:
`transport.securityPolicy`, `flowCredit`, `connectionBuffer`, `ready`,
`reconnectOutcome` and the rest. Replace `is IRpcSecurityPolicyAware` and
similar checks with the member. A custom transport adds the members, or
`extends IRpcTransport`. A decorator over `RpcClientConnection.transport`
that forwards `reconnectOutcome` keeps `RpcRetryInterceptor` waiting for the
reconnect.

**Stream-id resume is opt-in.** `lastIssuedStreamId` and
`resumeStreamIdsAfter` have defaults that throw, and a transport that
implements them says so with `supportsStreamIdResume => true`. A server-side
or test transport no longer writes them. `RpcClientConnection` refuses a
transport without them, with `RpcClientDisconnected(reason: UnsupportedError)`,
instead of reusing ids after a reconnect. A decorator forwards
`supportsStreamIdResume` with the other two.

**Reconnect lives in one layer, `RpcClientConnection`.** `transport.reconnect()`
and `endpoint.reconnect()` are gone. Wrap the transport factory in
`RpcClientConnection`; `forceReconnect()` replaces a manual reconnect.
`transportFactory` opens a new transport for every connection. It takes an
`RpcCancellationToken`, cancelled when the attempt is abandoned; a factory
that has no use for it is written `(_) => ...`. The connection waits for a transport to be ready and learns from the transport when the
connection is lost.

**Call shapes are built by the endpoint.** `UnaryCaller`, the stream callers and
the stream responders are no longer built by hand. Use the endpoint calls
(`unary`, `serverStream`, ...) or generated callers.

**Errors.** `RpcException` is abstract, and every error carries a gRPC status.
No error message is a contract: match on the type or the status.

**Renamed and replaced:**

| Was | Becomes |
|---|---|
| `RpcInMemoryTransport.pair()` | `RpcChannelTransport.memoryPair()` |
| `connectionLost` on a transport | `incomingMessages` ends: the transport closes |
| `onEndpointCreated:` / `onPeerEndpointCreated:` | `mode: RpcResponderMode(...)` / `RpcPeerMode(...)`; contracts only: `RpcResponderMode.contracts([...])` |
| `logger:` on the three endpoints, `RpcConnectionHost(endpointLogger:)` | `logController:` |
| `RpcConnectionLogger` | `LogScope` |
| `RpcCodec.withDecoder(T.fromJson)`, `RpcCodec.fromBytes` | `RpcCodec<T>(T.fromJson)` |
| `RpcMessage` | not exported; a transport works with `RpcTransportMessage` |
| `RpcDirectMultiplexedChannel` | not exported; `RpcChannelTransport.memoryPair()` |
| `IRpcChannelProtocolClose.closeForProtocolError(reason)` | `IRpcChannel.closeFor(RpcCloseForProtocolError(reason))`, with a default; a channel `extends IRpcChannel` to inherit it |
| `transferMode:` on `unaryRequest` | the contract's transfer mode |
| `RpcMethodKind` in `@RpcMethod` | `RpcMethodType` |
| a hand-written observer of the four `intercept*` methods | `RpcCallObserverInterceptor` |
| `RpcEndpointPingResult.responderTransportType`, the ping timestamp and transport headers | gone; `x-rpc-pong-timestamp` is microseconds since the epoch |
| `RpcBool` / `RpcString` returning a default on bad input | `FormatException` |
| header count and size limits on `RpcContext` | `RpcSecurityPolicy` |
| health metric `clientStreamBuffers` | `preBindBuffers` |
| `RpcDeadlineExceededException(deadline, timeout)` and its `timeout` | `RpcDeadlineExceededException(deadline)` |
| `RpcContextUtils` | not exported; the endpoint gives a call without a trace id one, `RpcContext.withTraceId(id)` joins a trace, `RpcContext.generateTraceId()` mints one ahead of the call. Spans belong to `rpc_dart_opentelemetry` |
| `ctx.createChild()`, `ctx.createChildWith(headers:, timeout:)`, `RpcContextBuilder.inheritFrom(ctx)` | `ctx.forward(headers:, timeout:)`, which drops this context's credentials; pass one on by naming it in `headers` |
| `RpcContextBuilder` | the `RpcContext` factories and `with...` copies; `withBearerAuth`, `withBasicAuth` and `withApiKey` are on `RpcContext` |
| `RpcContextUtils.merge(left, right)` | gone; chain `with...` copies |
| `RpcContextExtensions` | gone; `forward` is a method of `RpcContext` |
| `cancelMethod`, `cancelAllMethods`, `isMethodActive`, `getActiveCallsCount`, `getCancellationTokensForMethod` on a contract | the endpoint's `cancelMethod(service, method)`, `cancelService(service)`, `activeCallCount(service, method)`; a service method may now have any of these names |
| `endpoint.cancelAllMethods`, `endpoint.cancelServiceMethods` | `cancelAll`, `cancelService` |
| `RpcCallerEndpoint.start`, `RpcEndpointBase.start` | gone; a caller needs no start, a responder or peer endpoint still has `start()` |
| `ping(timeout: d)` | `ping(context: RpcContext.withTimeout(d))`; the context's deadline is the one bound, as for any call |
| `endpoint.unaryRequest` | `endpoint.unary`, named like the other three shapes |
| `RpcRateLimiter(nowMicros:)` | `clock:`, a `DateTime Function()` like `RpcContext.withClock` and `LogController(clock:)`; the default stays a monotonic stopwatch |
| `endpoint.getCancellationTokensForMethod` | gone; `activeCallCount` to count, a token in the context to cancel one call |
| `SpanStatus` | `LogSpanStatus`; it no longer clashes with OpenTelemetry's `SpanStatus` |
| `RpcStatus` as `int` constants, `RpcStatusException.statusCode` an `int` | `RpcStatus` is an enum with `code` and `grpcName`, `statusCode` is one of its values, `RpcStatus.fromCode(n)` reads a wire number (outside 0..16 is `unknown`); `RpcStatus.isFault(code)` is `status.isFault` |
| `RpcPeerContract(..., responderDataTransferMode: m)` | `dataTransferMode: m`, as on the other two contracts |
| `RpcCallScope.disposerTimeout = d` (a static, for the whole isolate) | `RpcCallScope(disposerTimeout: d)`; `RpcCallScope.defaultDisposerTimeout` |
| `RpcHeaders.xRouteService` | gone; routing uses the method path |
| `const RpcCancelledException(...)`, `const CircuitBreakerOpenException()` | the same without `const` |
| `RpcList.toMutableList()`, `where` returning `RpcList` | `RpcList` is an `Iterable`: `toList()` copies, `where` returns an `Iterable`, `for`-in works |
| `LogSpanHandle(...)`, `SpanStartCallback` / `SpanEventCallback` / `SpanCompleteCallback` | `LogScope.startSpan` / `withSpan` |
| endpoint pipeline members (`handleUnary` and the other three, `start*Listening`, `close*Resources`, `collect*Metrics`, `registeredMethods`, `registeredMethodBindings`, `validateMethodExists`, `getCancellationToken`, `responderIsListening`) and `RpcResponderContract.registrations` | not public; `collectEndpointMetrics()` for the metrics |
| `IRpcMiddleware`, `addMiddleware`, `RpcEndpointMetrics.middlewareCount` | an `IRpcInterceptor`, the one way to wrap a call: it changes the request before `next` or maps the request or response stream |
| `RpcMiddlewareContext` | `RpcCallInfo`, whose `direction` is always set |

**`grpc.health.v1` speaks protobuf.** `GrpcHealthCheckContract` was CBOR on the
wire, so real gRPC health checkers could not read it. `Check` on an unknown
service fails with `NOT_FOUND`. The messages lose `toJson`/`fromJson`; use
their `codec`.

### Behaviour you will notice without changing code

- **A server compresses responses only when told to.** It used to gzip every
  response for a client that accepted gzip. `compressionEnabled: true` on the
  server, `RpcConnectionHost` or `RpcResponderEndpoint` turns it on; on
  `RpcPeerEndpoint` the existing flag now covers responses as well.
- **No deadline means no timeout.** A call without a deadline waits until it
  ends. Set a deadline on the context to bound it.
- **Internal error text stays on the server.** An unexpected exception reaches
  the caller as `INTERNAL` without its message. Throw an `RpcStatusException`
  to send your own status and text.
- **A response that ends without a gRPC status is `INTERNAL`**, not a success
  with partial data, and it is not retried.
- **`RESOURCE_EXHAUSTED` is retried only with server pushback.**
- **A call after the peer died is `UNAVAILABLE`** on every transport.
- **A second message on a single-message side fails the call.**
- **Stricter registration.** A method name may not contain a dot, and names the
  wire grammar refuses are refused at registration.
- **`maxActiveStreams` counts a call until it ends**, not until half-close.
- **An un-consumed stream is bounded by queue depth** as well as bytes, and
  buffering is charged to one per-connection total. A peer that sends without
  reading gets `RESOURCE_EXHAUSTED` instead of growing memory.
- **One CBOR message has an item budget**, so a small message cannot decode to
  a huge object graph.
- **A derived context cannot outlive its parent.**
- **`IRpcServer.endpoints` lists peer-mode connections too.** An
  `RpcPeerEndpoint` is an `RpcResponderEndpoint` that can also start calls.
- **`global` in the rate limiter is a ceiling**, not a fallback.
- **A request encoding is declared only if a codec for it is registered.**
- **A peer that repeats the same fault is logged once.**
- **CBOR refuses a value it cannot encode.** A `DateTime`, enum, `Set`,
  `BigInt` or `Duration` without a `toJson()` throws `ArgumentError` instead of
  going out as its `toString()`. A `toJson()` that returns a number or a bool is
  encoded as that value, not as a string.
- **`x-route-service` is no longer sent.**
- **Misusing a primitive is a Dart error**: comparing an `RpcInt` with a raw
  `int` throws `UnsupportedError`, a wrong operand `ArgumentError`, instead of
  an `RpcStatusException` whose text would reach the peer from a handler.
- **Every `x-rpc-*` header is reserved** (`RpcHeaders.reservedPrefix`): user
  metadata under that prefix is dropped when sending. The cancellation notice
  moved into it, as `x-rpc-client-cancelled` and `x-rpc-cancellation-reason`.

### New

- `IRpcInterceptor.check`: a check that runs for every call shape.
- `RpcCallObserverInterceptor`: observe every call of every shape. An interceptor
  can tell an outgoing call from an incoming one.
- `IRpcServer.stop(drainTimeout:)` stops admitting and waits for in-flight
  calls; `pair()` builds a client.
- For transport authors: `RpcWriteBacklog` (with `reads`), `RpcWriteCoalescer`,
  `RpcConnectionHost`, `RpcTrailers`, `drainUntilIdle`, `notifyWithoutDying`.
- `approxJsonBytes` for byte-bounded message buffers; `platformGzip`, the
  built-in gzip codec.
- Unary tolerates a gRPC frame split across transport messages.
- An Agent Skill ships with the package: `dart run skills get`.

---

## rpc_dart_generator (next version)

- **Regenerate.** A per-method codec override now applies to its own method
  only, as `<Base>Codecs.requestOf<Method>` / `responseOf<Method>`. It used to
  apply to every method with the same type.
- Every type a gRPC descriptor names is described; stored fields are described;
  codecs compile for bare primitives.
- A service method named like a member of the contract bases (`dispose`,
  `setup`, `endpoint`, `callUnary`, ...) fails the build with that name,
  instead of producing code that does not compile.
- A bare `double` sent from a web peer decodes on the VM: dart2js writes 2.0
  as a CBOR integer, and the generated decoder now reads it through `num`.

## rpc_dart_framework (next version)

- **Breaking:**
  - `RpcApp.server(server: (onEndpoint) => ...)` becomes `server: (mode) => ... mode: mode`.
  - `RpcCallEvent.callType` / `RpcSpyEntry.callType` strings become `RpcMethodType`. `RpcSpyEntry` is `RpcCallEvent`, with `outcome`; `calledAt` is gone.
  - App health is typed: `modules['X'].level` (`RpcHealthStatus`) and `endpoints[i]` (`RpcEndpointHealth`). Maps remain only in `toJson()`.
  - The typedef `RpcCallObserver` is `RpcCallEventHandler`.
  - `RpcTestApp` runs as an `RpcApp`.
- **New:** `RpcAppConfig.copyWith`.
- **Fixed:**
  - Modules start before the server accepts connections, and every teardown stops the server before the modules.
  - Only modules that started are stopped. `stop()` waits for a `start()` in progress, does not wait on a hung `onStart`, and concurrent `stop()` calls share one stop.
  - A dead isolate worker makes the app unhealthy.
  - A failed `RpcTestApp.start` rolls back what it started.

## rpc_dart_compression (next version)

- **Breaking:** `maxDecompressedSize: null` means no limit; `-1` is gone. A
  decompressor's size overrun is `RESOURCE_EXHAUSTED`.
- Native platforms always decompress through `dart:io` and stop at the limit
  mid-stream. Gzip shorter than an empty frame is rejected.

## rpc_dart_grpc_reflection (next version)

- **Breaking:** `processRequestForTest` and `parseFileDescriptorSet` are gone.
- Protobuf is read and written through core. A missing dependency set is
  warned about once.

## rpc_dart_log (next version)

- Record buffers are bounded in bytes as well as records.
- The collector contract is generated and reports real ids. Remote text is
  escaped in the console and the MCP view. The collector upgrades through the
  transport's guards.

## rpc_dart_opentelemetry (next version)

- **Breaking:** `OtelRpcInterceptorBase.startSpan(call, String callType)`
  becomes `startSpan(call, RpcMethodType type)`; `callTypeAttribute(type)`
  gives the attribute value. The interceptors are built on
  `RpcCallObserverInterceptor`, and `OtelRpcInterceptorBase` is exported.
- The recorded status is the one the caller receives.

## rpc_dart_websocket (next version)

- **Breaking:**
  - `headersProvider:` and `reconnectFactory:` on the caller are replaced by
    `RpcClientConnection`; build `headers:` inside its factory, which runs for
    every connection.
  - A failed connect is a gRPC status, and a disconnected transport refuses in
    one shape.
  - A stopped server refuses connections instead of abandoning them.
  - The endpoint callbacks are refused. `createWithContracts` passes
    `logController` through.
- **New:**
  - `maxConnections`.
  - `bindRpcWebSocketHttpServer` bounds the upgrade request.
  - The caller transport reports when it is ready.
  - Half-open detection where the platform drops ping.
- **Hardening:**
  - `connect()` is bounded by default.
  - An unfinished message is bounded before `dart:io` buffers it, and a message in thousands of fragments is refused.
  - Inbound pings are rate-limited.
  - Reading stops while 1 MiB of answers is unsent.
  - Credentials and close reasons no longer reach the log unescaped.
  - Several inputs that killed the server no longer do: a repeated `Sec-WebSocket-Key` and a refused frame during the handshake.
- **Fixed:**
  - `RpcClientConnection` reconnects after a server restart.
  - A peer client can answer calls.
  - A reused peer stream id gets its own answer.
  - An ended connection returns its `maxConnections` slot.

## rpc_dart_socket (new package, first release)

Unix domain socket and TCP transport over core's channel framing: a server with
a lock file guarding a live socket path, frames of one turn written together,
and reading stopped while a peer's answers go unsent. The connection opens with
core's frame preface; the server builds no endpoint before it arrives and
drops a silent peer after `prefaceTimeout`. `connectRpcSocket` is bounded by a
timeout and abandoned on a cancellation token.

## rpc_dart_http (next version)

- **Breaking:**
  - The security policy is `policy:`, and `policy: null` (checks off) is gone: the default policy applies.
  - A redirect is a refusal, not a second request.
  - Response headers are no longer split on the comma.
  - The bare responder transport gets the limits its server has.
- **New:**
  - A per-chunk body idle timeout, on by default.
  - An unfinished request header block is bounded.
- **Fixed:**
  - `maxActiveStreams` is enforced on the caller.
  - Abandoning a call abandons the request.
  - A caller's cancel reaches the handler.
  - Error details reach the caller over HTTP/1.1.
  - Repeated request metadata is joined, not dropped.
  - Routing uses the path relative to the mount.
  - A failed request no longer logs the base URL's password.
  - Stop and restart wait for the drain in flight.

## rpc_dart_http2 (next version)

- **Breaking:**
  - The security policy is `policy:`; header conversion requires one.
  - Requires `http2 ^3.1.0`.
  - A failed connect is a status.
  - Reconnect lives in `RpcClientConnection`.
  - A cancel is not a request, and a live id refuses a second open.
- **New:**
  - A connection cap.
  - The connect is bounded, not just the proxy's reply.
  - The caller transport is ready once the peer sends SETTINGS.
  - Health details count outgoing pumps.
- **Fixed:**
  - One stream's error no longer fails every call.
  - A message larger than the window is no longer refused.
  - A peer that never sends SETTINGS is dropped.
  - The TLS server selects h2 in ALPN, and a TLS peer that did not choose h2 is refused.
  - `secureConnect` works through a CONNECT proxy, and GOAWAY is seen through one.
  - Reading stops while 1 MiB of answers is unsent.
  - A stream cut mid-message is an error on every ending.

## rpc_dart_isolate (next version)

- `spawn` takes a logger for the host transport.
- A frame that fails to decode does not kill the isolate. A web worker gets
  its window and dies cleanly.
- One channel serves the VM and the web. Small payloads cross as bytes.
- **Rebuild your worker script.** A web worker and its page exchange a bridge
  protocol version. A worker of another version, or a stale copy from the
  browser cache, fails `spawn` with `FAILED_PRECONDITION` naming both. A
  worker that never answers `ready` fails after `startupTimeout` instead of
  being let through after 5 seconds.

## rpc_dart_wasm (next version)

- `fromBridge` takes a logger.
- **Android:** a long guest stream is not cut off, a sandbox killed while idle is reported, and a runtime loads after the sandbox died.
- **iOS:** the guest queue is bounded, and concurrent support probes agree.
- **Both platforms:**
  - Frames sent while either side boots are kept.
  - Guest timers fire in deadline order.
  - A client-stream call to a dart2wasm guest works.
  - `canRunDartWasm` says no where load would refuse.

## rpc_data, rpc_notify, rpc_blob*

- A watcher or subscriber that stops reading no longer holds every change or
  the topic. Buffered events are sized with core's `approxJsonBytes`.
- A data error keeps its status and code on the wire.
- rpc_blob: one contract for a conditional delete across all four adapters.
