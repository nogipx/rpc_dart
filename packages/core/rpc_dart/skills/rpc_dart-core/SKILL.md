---
name: rpc_dart-core
description: "Write, wire, test and debug code that uses the rpc_dart RPC framework (package:rpc_dart): responder and caller contracts (generated from an annotated interface by rpc_dart_generator, the recommended way, or written by hand), RpcResponderEndpoint / RpcCallerEndpoint / RpcPeerEndpoint, unary and streaming methods, codecs and zero-copy, RpcContext deadlines, cancellation and metadata, RpcStatusException errors, retry / circuit breaker / rate limiting, RpcSecurityPolicy limits, LogController logging, health checks, and tests over RpcChannelTransport.memoryPair() or pair(). Use it whenever Dart code imports package:rpc_dart or any rpc_dart_* transport package, or the user asks to add an RPC service, method or transport to such a project."
---

# rpc_dart core

rpc_dart is a transport-agnostic RPC framework. One contract runs over any
transport: in-process, HTTP/2 (real gRPC wire), HTTP/1.1, WebSocket, isolates,
or a WebAssembly bridge. This skill covers the core package only. A transport
package changes how you build the transport object and nothing else; its README
has the constructor and server setup.

## The model

```
caller contract -> RpcCallerEndpoint -> IRpcTransport ~~ IRpcTransport -> RpcResponderEndpoint -> responder contract
```

- **Responder contract** (`extends RpcResponderContract`): registers handlers in
  `setup()`. Each handler takes `{RpcContext? context}`.
- **Caller contract** (`extends RpcCallerContract`, abstract): typed methods
  that call `callUnary` / `callServerStream` / `callClientStream` /
  `callBidirectionalStream`.
- **Endpoints** own one transport each. Register responder contracts on an
  `RpcResponderEndpoint` and call `start()`. Bind caller contracts to an
  `RpcCallerEndpoint`. An `RpcPeerEndpoint` does both over one transport.
- **Transport**: anything implementing `IRpcTransport`. The core gives you
  `RpcChannelTransport.memoryPair()` (zero-copy, in process),
  `RpcChannelTransport.pair()` (real frames, in memory) and
  `RpcChannelTransport.fromChannel(...)` (your own byte pipe).

## Define contracts by code generation

**The recommended way to define a service** is one annotated abstract
interface (`@RpcService`, `@RpcMethod.unary` / `.serverStream` /
`.clientStream` / `.bidirectionalStream`) run through `rpc_dart_generator` with
`build_runner`. It generates the caller, the responder base class, the
method-name constants and the codecs from that single declaration, so the two
sides cannot drift and codec mistakes surface at build time. Read
[code-generation.md](references/code-generation.md) before adding a service.

Write contracts by hand, as in the example below, only when the project cannot
run `build_runner`, or to understand what the generated code does.

## Minimal working example (hand-written contracts)

```dart
import 'package:rpc_dart/rpc_dart.dart';

final class GreeterResponder extends RpcResponderContract {
  GreeterResponder() : super('Greeter');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'hello',
      handler: _hello,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }

  Future<RpcString> _hello(RpcString request, {RpcContext? context}) async =>
      RpcString('Hello, ${request.value}');
}

final class GreeterCaller extends RpcCallerContract {
  GreeterCaller(RpcCallerEndpoint endpoint) : super('Greeter', endpoint);

  Future<RpcString> hello(RpcString request, {RpcContext? context}) =>
      callUnary<RpcString, RpcString>(
        methodName: 'hello',
        request: request,
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        context: context,
      );
}

Future<void> main() async {
  final (clientTransport, serverTransport) = RpcChannelTransport.memoryPair();
  final server = RpcResponderEndpoint(transport: serverTransport)
    ..registerServiceContract(GreeterResponder())
    ..start();
  final client = RpcCallerEndpoint(transport: clientTransport);

  final reply = await GreeterCaller(client).hello(
    const RpcString('rpc_dart'),
    context: RpcContext.withTimeout(const Duration(seconds: 5)),
  );
  print(reply.value);

  await client.close();
  await server.close();
}
```

Give every method codecs unless it is in-process only. Network transports are
not zero-copy, and a method without codecs fails on them.

## Rules that prevent most mistakes

1. **Errors.** Throw `RpcStatusException(RpcStatus.xxx, 'message')` from a
   handler to send a status to the caller. Any other exception reaches the
   caller as INTERNAL. A bare `RpcException` keeps its message, but anything
   that is not an `RpcException` arrives as `'Internal server error'`.
   `RpcException` has only `message`: there is no `code` or `details`.
2. **Catch on `statusCode`, not on subtypes.** A status sent by the server
   always arrives as a plain `RpcStatusException`. So
   `on RpcCancelledException` does not catch a CANCELLED that came from the
   server.
3. **Responder needs `start()`.** Without it calls never get an answer: they
   hang, they do not fail.
4. **Endpoints take `logger:` as a `LogController`.** Not a `LogScope`. Inside
   a handler, log through `context?.log`, which is already scoped to
   `rpc.responder.<Service>.<method>`.
5. **There are no `interceptors:` or `middlewares:` constructor parameters.**
   Use `addInterceptor` / `addMiddleware`. The first interceptor added is the
   outermost. Add a circuit breaker before a retry interceptor, or the retry
   will retry `CircuitBreakerOpenException` (UNAVAILABLE).
6. **Limits live on the transport, not the endpoint.** Pass an
   `RpcSecurityPolicy` to the transport factory (`memoryPair(policy:)`,
   `pair(policy:)`, or a transport package's `policy` parameter). Endpoints
   have no `policy:` parameter.
7. **`memoryPair()` hides wire bugs.** It skips codecs on `auto` contracts and
   never enforces byte limits. If production uses a network transport, run
   tests over `pair()` too.
8. **Bound every call.** Give a deadline (`RpcContext.withTimeout`,
   `ctx.withTimeout`) or a cancellation token. `ping()` without `timeout:`
   waits forever, and its timeout throws `dart:async` `TimeoutException`.
9. **A cancelled token poisons its context.** After `token.cancel()`, or after
   cancelling an early stream subscription that used that context, every
   later call with the same context fails at once with CANCELLED. Make a new
   token or context per logical operation.
10. **Header names are lowercased, and invalid names are dropped silently.**
    Values must be printable ASCII. Use a `-bin` suffix for binary values.
    Setting `x-trace-id` / `x-request-id` as headers does nothing; use the
    context's `traceId` / `requestId` instead.
11. **Use `RpcChannelTransport.memoryPair()`.** `RpcInMemoryTransport` is a
    deprecated forwarder.
12. **`RpcCallerContract` is abstract.** Subclass it; do not instantiate it.
    The untyped endpoint API (`unaryRequest`, `serverStream`, ...) exists, but
    prefer caller contracts: they check codecs against the transfer mode.

## References

Read the file for the task at hand. Each one has rules, a compiling example,
and a pitfalls list.

| Task | File |
| --- | --- |
| Define a service from an annotated interface with `rpc_dart_generator` (recommended); transfer modes, peer services, versioning | [code-generation.md](references/code-generation.md) |
| Hand-written contracts; endpoints; peer mode; middleware vs interceptors; annotation reference | [contracts-and-endpoints.md](references/contracts-and-endpoints.md) |
| Server, client and bidirectional streams; cancellation; backpressure | [streaming.md](references/streaming.md) |
| Serialization (`IRpcSerializable`, `RpcCodec`, `RpcBinaryCodec`, primitives), transfer modes, compression | [codecs-and-compression.md](references/codecs-and-compression.md) |
| Deadlines, cancellation, headers and metadata rules, per-call scope | [context-and-metadata.md](references/context-and-metadata.md) |
| Status codes, error details, retry, circuit breaker, rate limiting, auto-reconnect | [errors-and-resilience.md](references/errors-and-resilience.md) |
| `RpcSecurityPolicy` fields and defaults, what each limit does when it trips, flow control | [security-and-flow-control.md](references/security-and-flow-control.md) |
| `LogController`, `LogScope`, outputs, health, ping, gRPC health service | [logging-and-health.md](references/logging-and-health.md) |
| Testing over `memoryPair()` and `pair()`, capturing logs | [testing.md](references/testing.md) |
| Which transport package to use; reconnecting | [choosing-a-transport.md](references/choosing-a-transport.md) |

## Outside this skill

- Constructing a specific transport and running its server: read the README of
  `rpc_dart_http2`, `rpc_dart_http`, `rpc_dart_websocket`, `rpc_dart_isolate`
  or `rpc_dart_wasm`.
- The generator's full reference (gRPC reflection descriptors,
  `@RpcProtoField`, every generated member): the `rpc_dart_generator` README.
  The everyday workflow is in [code-generation.md](references/code-generation.md).
- Shipping logs or traces out of the process: `rpc_dart_log`,
  `rpc_dart_opentelemetry`. Gzip compression codec: `rpc_dart_compression`.
