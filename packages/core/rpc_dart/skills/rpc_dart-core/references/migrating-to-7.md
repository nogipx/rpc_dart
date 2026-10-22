<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Migrating from rpc_dart 6.x to 7.0

Work in this order: deploy plan, compile errors, generated code, behaviour,
tests. The compiler finds most of the work; the behaviour section lists what it
cannot find.

## 1. Plan the deploy

- **Channel transports cannot mix 6.x and 7.0.** websocket, socket, wasm and
  `RpcChannelTransport.fromChannel` changed their wire format. Upgrade client
  and server in one release. HTTP/2 and HTTP/1.1 speak gRPC on the wire and
  are not affected by this change.
- From 7.0 on, a channel connection opens with a version preface. The server
  answers in the client's version, so later releases upgrade **servers
  first**. A peer of another version fails every call with
  `FAILED_PRECONDITION`, and one that is not rpc_dart with `UNKNOWN`.
- **Rebuild every web worker script** (`rpc_dart_isolate` on the web). The page
  and the worker exchange a protocol version, and a stale worker, a cached copy
  included, fails `spawn` with `FAILED_PRECONDITION`.
- A hand-written byte peer of a channel transport writes
  `RpcChannelFrame.preface` before its first frame.

## 2. Fix compile errors

Imports: application code keeps `package:rpc_dart/rpc_dart.dart`. Code that
builds a transport, a channel or frames imports
`package:rpc_dart/transport.dart`, which re-exports the first.

| 6.x | 7.0 |
| --- | --- |
| `RpcInMemoryTransport.pair()` | `RpcChannelTransport.memoryPair()` |
| `transport.reconnect()`, `endpoint.reconnect()` | wrap the transport factory in `RpcClientConnection`; `forceReconnect()` |
| listening to `connectionLost` | the transport closes; `RpcClientConnection` reconnects |
| `RpcClientConnection(transportFactory: () => ...)` | `transportFactory: (cancellation) => ...`, or `(_) => ...` |
| `onEndpointCreated:` on a server | `mode: RpcResponderMode((endpoint) { ... })` |
| `onPeerEndpointCreated:` | `mode: RpcPeerMode(...)` |
| contracts list on a server | `mode: RpcResponderMode.contracts([...])` |
| `logger:` on an endpoint, `RpcConnectionHost(endpointLogger:)` | `logController:` (a `LogController`) |
| `RpcConnectionLogger` | `LogScope` |
| `RpcCodec.withDecoder(T.fromJson)`, `RpcCodec.fromBytes` | `RpcCodec<T>(T.fromJson)` |
| `UnaryCaller`, stream callers and responders built by hand | endpoint calls (`unaryRequest`, `serverStream`, ...) or a caller contract |
| `transferMode:` on `unaryRequest` | the contract's transfer mode |
| `kind: RpcMethodKind.x` in `@RpcMethod` | `RpcMethodType.x`, or the named constructors `@RpcMethod.unary(...)` |
| one interceptor overriding the four `intercept*` methods to observe calls | `extends RpcCallObserverInterceptor<S>` |
| `RpcEndpointPingResult.responderTransportType` | gone |
| header count and size limits on `RpcContext` | `RpcSecurityPolicy` (`maxHeaders`, `maxHeaderNameBytes`, `maxHeaderValueBytes`) |
| health detail `clientStreamBuffers` | `preBindBuffers` |
| `RpcDeadlineExceededException(deadline, timeout)` | `RpcDeadlineExceededException(deadline)` |
| `RpcContextUtils.withTracing(...)`, `RpcContextUtils.generateTraceId()` | nothing: the endpoint gives a call without a trace id one; `RpcContext.withTraceId(id)` to join a trace. Spans come from `rpc_dart_opentelemetry` |
| `RpcHeaders.xRouteService` | gone; route on the method path |
| `const RpcCancelledException(...)`, `const CircuitBreakerOpenException()` | drop `const` |
| `RpcList.toMutableList()` | `toList()`; `RpcList` is an `Iterable` and `where` returns an `Iterable` |
| `LogSpanHandle(...)` and the `Span*Callback` typedefs | `LogScope.startSpan` / `withSpan` |
| endpoint pipeline members (`handleUnary`, `startResponderListening`, `collectResponderMetrics`, `registeredMethods`, ...) and `contract.registrations` | not public; `collectEndpointMetrics()` for metrics |
| `implements IRpcServer` / `implements RpcCompressionCodec` | `extends` (both still compile; `extends` keeps compiling when a member is added) |
| `RpcMessage`, `RpcDirectMultiplexedChannel` | not exported; `RpcTransportMessage`, `memoryPair()` |
| `endpoint.clientStream(...)(requests)` | `endpoint.clientStream(..., requests: requests)`, as `callClientStream` |
| `call.updateContext(ctx)` / `call.context = ctx` in an interceptor | pass `ctx` to `next(ctx, request)` |
| `ctx.withValue('key', v)`, `ctx.getValue<T>('key')` | a typed key: `const key = RpcContextKey<T>('key')`, then `withValue(key, v)` / `getValue(key)` |
| `getValue<RpcCallScope>(RpcCallScope)` | `ctx.callScope` |
| `endpoint.collectEndpointMetrics()['openStreams']` | `endpoint.collectEndpointMetrics().openStreams` (`RpcEndpointMetrics`; `toJson()` for the map) |
| `RpcContextBuilder()...build()` | `RpcContext.empty()` or a factory, then `with...` copies; `withBearerAuth`, `withBasicAuth`, `withApiKey` are on `RpcContext` |
| `ctx.createChild()`, `ctx.createChildWith(...)`, `RpcContextBuilder.inheritFrom(ctx)` | `ctx.forward(headers:, timeout:)`; it drops `ctx`'s credentials, so pass one on by naming it in `headers` |
| `RpcContextUtils.merge(a, b)` | gone; chain `with...` copies |
| `contract.cancelMethod(m)`, `contract.cancelAllMethods()`, `contract.isMethodActive(m)`, `contract.getActiveCallsCount(m)` | `endpoint.cancelMethod(service, m)`, `endpoint.cancelService(service)`, `endpoint.activeCallCount(service, m)` |
| `endpoint.cancelAllMethods()`, `endpoint.cancelServiceMethods(s)` | `cancelAll()`, `cancelService(s)` |
| `start()` on an `RpcCallerEndpoint` | delete the call; only a responder or peer endpoint starts |
| `endpoint.ping(timeout: d)` | `endpoint.ping(context: RpcContext.withTimeout(d))` |
| `getCancellationTokensForMethod(...)` | gone; `activeCallCount`, or a token in the call's context |
| `SpanStatus` | `LogSpanStatus` |
| `RpcStatus` `int` constants; `RpcStatusException(14, ...)`; `int status = e.statusCode` | `RpcStatus` is an enum and `statusCode` its value: `RpcStatus.unavailable`, `RpcStatus.fromCode(14)`; the wire number is `status.code` |
| `RpcStatus.isFault(code)` | `status.isFault` |
| `RpcPeerContract(..., responderDataTransferMode: m)` | `dataTransferMode: m`, as on the other two contracts |
| `implements IRpcChannelProtocolClose` | `extends IRpcChannel` and override `closeFor(RpcChannelCloseReason)` |
| `IRpcMiddleware`, `endpoint.addMiddleware(m)`, `middlewares:` on `RpcApp` / `RpcTestApp` | an `IRpcInterceptor`: change the request before `next`, map the request or response stream for each message |
| `RpcMiddlewareContext` | `RpcCallInfo`; `direction:` is required |

`RpcException` is abstract: throw `RpcStatusException(RpcStatus.x, '...')`.
Match errors on the type or on `statusCode`, never on the message text.

Reconnect, the 7.0 way. The factory runs once per connection, so per-connection
values (an auth header, a fresh token) are built inside it:

```dart
import 'package:rpc_dart/rpc_dart.dart';

Future<void> reconnecting(Future<IRpcTransport> Function() open) async {
  final connection = RpcClientConnection(transportFactory: (_) => open());
  final endpoint = RpcCallerEndpoint(transport: connection.transport);
  connection.connect();

  // Bind caller contracts to `endpoint` once; they survive reconnects.

  await endpoint.close();
  await connection.dispose();
}
```

Companion packages:

| Package | 6.x | 7.0 |
| --- | --- | --- |
| rpc_dart_framework | `RpcApp.server(server: (onEndpoint) => ...)` | `server: (mode) => ...(mode: mode)` |
| rpc_dart_framework | `callType` strings on `RpcCallEvent` / `RpcSpyEntry` | `RpcMethodType`; `RpcSpyEntry` is `RpcCallEvent`, `calledAt` is gone |
| rpc_dart_framework | typedef `RpcCallObserver` | `RpcCallEventHandler` |
| rpc_dart_framework | app health as maps | typed: `modules['X'].level`, `endpoints[i]`; maps only in `toJson()` |
| rpc_dart_compression | `maxDecompressedSize: -1` | `null` means no limit |
| rpc_dart_grpc_reflection | `processRequestForTest`, `parseFileDescriptorSet` | gone |
| rpc_dart_opentelemetry | `startSpan(call, String callType)` | `startSpan(call, RpcMethodType type)` |
| rpc_dart_websocket | `headersProvider:`, `reconnectFactory:` | `RpcClientConnection` whose factory calls `connect(..., headers: ...)` |
| rpc_dart_http, rpc_dart_http2 | security policy parameter | `policy:`; `policy: null` is gone |

## 3. Regenerate

Run `dart run build_runner build --delete-conflicting-outputs` in every package
with generated contracts. A per-method codec override now applies to its own
method only (`<Base>Codecs.requestOf<Method>` / `responseOf<Method>`); it used
to apply to every method of the same type.

## 4. Check behaviour the compiler cannot see

- **No deadline means no timeout.** A call without a deadline waits until it
  ends. Give every call a deadline or a cancellation token.
- **Unexpected exceptions reach the caller as `INTERNAL` without their text.**
  A handler that wants the caller to see a message throws
  `RpcStatusException`.
- **A response that ends without a status is `INTERNAL`**, not a success with
  partial data, and it is not retried.
- **`RESOURCE_EXHAUSTED` is retried only with server pushback.**
- **A second message on a single-message side fails the call.**
- **Registration is stricter.** A method name may not contain a dot.
- **`RpcBool` / `RpcString` throw `FormatException` on bad input** instead of
  returning a default. `RpcInt.fromJson` throws on a fraction or a non-finite
  number instead of truncating it, and `RpcInt` arithmetic with an int result
  throws `ArgumentError` on a fractional operand; `RpcInt / x` divides by the
  exact `x`.
- **A retry waits the delay the server's `RpcRetryInfo` asks for**, not its
  own backoff, when the delay is positive.
- **A metadata violation is not an `ArgumentError`.** A header the security
  policy refuses throws `RpcMetadataViolationException` (INVALID_ARGUMENT, exported
  from `rpc_dart.dart`); a `catch (ArgumentError)` no longer catches it.
- **A zero-copy contract on a byte-only transport fails at registration**,
  not on every call.
- **CBOR throws `ArgumentError` for a `DateTime`, enum, `Set`, `BigInt` or
  `Duration` without `toJson()`.** Convert it in the message's `toJson`
  (`toIso8601String()`, `name`, `toList()`), or the call fails at send time.
- **`x-rpc-*` metadata is reserved** and dropped when sending. Rename your own
  headers that use the prefix.
- **A derived context cannot outlive its parent's deadline.**
- **`global` in the rate limiter is a ceiling**, not a fallback.
- **`maxActiveStreams` counts a call until it ends**, and a peer that sends
  without reading gets `RESOURCE_EXHAUSTED`. Raise the limits in
  `RpcSecurityPolicy` if a legitimate workload hits them.
- **A `switch` over an open type keeps a default branch**: minor releases may
  add values to `RpcHealthLevel`, `RpcClientConnectionState`,
  `RpcCallOutcome`, `RpcDataTransferMode`, `RpcContentTypeValidation`,
  `ConsoleFormat`, `LogSpanStatus`, `GrpcServingStatus`, `RateLimit` and
  `LogRecord`. `RpcMethodType`, `RpcCallDirection`, `CircuitBreakerState`,
  `RpcServiceKind`, `RpcServerMode` and `RpcLogLevel` are closed.

## 5. Verify

- Run the tests over `RpcChannelTransport.pair()` as well as `memoryPair()`:
  only `pair()` runs the codecs and the byte limits.
- Test one call through each production transport. A channel transport's
  `ready` now completes only after the server answered the preface, so a
  connection to the wrong port fails instead of reporting Online.
