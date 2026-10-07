<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Testing

## Rules

- Test end to end through real endpoints over an in-process transport pair.
  Do not mock endpoints or contracts.
- `RpcChannelTransport.memoryPair()` is zero-copy: objects pass by reference,
  codecs are skipped on `auto` contracts, byte limits never fire. Fast; use it
  for handler logic.
- `RpcChannelTransport.pair()` encodes real frames over an in-memory byte
  pipe: codecs run, `maxMessageLengthBytes` and metadata limits apply,
  compression headers are sent. It is NOT zero-copy.
- If production runs over a non-zero-copy transport (websocket, http, http2,
  wasm), run the suite (or at least one test per method) over `pair()`.
  `memoryPair()` hides serialization bugs: a field `toJson` forgets still
  arrives.
- Both factories take one `policy:` and give it to both halves. Use it to test
  limits; see `security-and-flow-control.md`.
- `RpcInMemoryTransport` is a deprecated forwarder. Do not use it.
- Start the responder (`..start()`) before calling. The caller needs no
  `start()`.
- Close both endpoints in `tearDown` / `addTearDown`. Closing the caller
  cancels its in-flight calls.
- Assert errors on `statusCode` (an `RpcStatus` constant), not on the
  message text or a concrete subclass.
- Bound every await on a call that could hang with a context deadline or
  `.timeout(...)`, so a bug fails the test instead of stalling the runner.

## Example

The contracts under test. They carry codecs, so the same suite also runs over
`pair()`. See `contracts-and-endpoints.md` for the full contract API.

```dart
import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

final class EchoResponder extends RpcResponderContract {
  EchoResponder() : super('Echo');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: _echo,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'slow',
      handler: _slow,
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
    addServerStreamMethod<RpcInt, RpcInt>(
      methodName: 'count',
      handler: _count,
      requestCodec: RpcInt.codec,
      responseCodec: RpcInt.codec,
    );
  }

  Future<RpcString> _echo(RpcString request, {RpcContext? context}) async {
    if (request.value.isEmpty) {
      throw RpcStatusException(RpcStatus.invalidArgument, 'empty input');
    }
    context?.log.info('echo', data: {'length': request.value.length});
    return request;
  }

  Future<RpcString> _slow(RpcString request, {RpcContext? context}) async {
    await Future<void>.delayed(const Duration(seconds: 5));
    return request;
  }

  Stream<RpcInt> _count(RpcInt request, {RpcContext? context}) async* {
    for (var i = 0; i < request.value; i++) {
      yield RpcInt(i);
    }
  }
}

final class EchoCaller extends RpcCallerContract {
  EchoCaller(RpcCallerEndpoint endpoint) : super('Echo', endpoint);

  Future<RpcString> echo(RpcString request, {RpcContext? context}) =>
      callUnary<RpcString, RpcString>(
        methodName: 'echo',
        request: request,
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        context: context,
      );

  Future<RpcString> slow(RpcString request, {RpcContext? context}) =>
      callUnary<RpcString, RpcString>(
        methodName: 'slow',
        request: request,
        requestCodec: RpcString.codec,
        responseCodec: RpcString.codec,
        context: context,
      );

  Stream<RpcInt> count(int n) => callServerStream<RpcInt, RpcInt>(
    methodName: 'count',
    request: RpcInt(n),
    requestCodec: RpcInt.codec,
    responseCodec: RpcInt.codec,
  );
}
```

```dart
Matcher throwsStatus(int code) => throwsA(
  isA<RpcStatusException>().having((e) => e.statusCode, 'statusCode', code),
);

void main() {
  late RpcCallerEndpoint callerEndpoint;
  late RpcResponderEndpoint responderEndpoint;
  late EchoCaller client;
  late RingBufferOutput logs;

  setUp(() {
    logs = RingBufferOutput(maxEntries: 500);
    final logger = LogController(minLevel: RpcLogLevel.info, outputs: [logs]);
    final (clientTransport, serverTransport) =
        RpcChannelTransport.memoryPair();
    responderEndpoint = RpcResponderEndpoint(
      transport: serverTransport,
      logger: logger,
    )
      ..registerServiceContract(EchoResponder())
      ..start();
    callerEndpoint = RpcCallerEndpoint(
      transport: clientTransport,
      logger: logger,
    );
    client = EchoCaller(callerEndpoint);
  });

  tearDown(() async {
    await callerEndpoint.close();
    await responderEndpoint.close();
  });

  test('unary round trip', () async {
    expect((await client.echo(const RpcString('hi'))).value, 'hi');
  });

  test('handler status reaches the caller', () async {
    await expectLater(
      client.echo(const RpcString('')),
      throwsStatus(RpcStatus.invalidArgument),
    );
  });

  test('deadline', () async {
    await expectLater(
      client.slow(
        const RpcString('x'),
        context: RpcContext.withTimeout(const Duration(milliseconds: 100)),
      ),
      throwsStatus(RpcStatus.deadlineExceeded),
    );
  });

  test('cancellation', () async {
    final token = RpcCancellationToken();
    final call = client.slow(
      const RpcString('x'),
      context: RpcContext.withCancellation(token),
    );
    Timer(const Duration(milliseconds: 50), () => token.cancel('user'));
    await expectLater(call, throwsStatus(RpcStatus.cancelled));
  });

  test('server stream', () async {
    await expectLater(
      client.count(3).map((m) => m.value),
      emitsInOrder([0, 1, 2, emitsDone]),
    );
  });

  test('handler log is captured', () async {
    await client.echo(const RpcString('abc'));
    final events = logs.entries.whereType<LogEvent>().where(
      (e) => e.message == 'echo',
    );
    expect(events.single.scope, 'rpc.responder.Echo.echo');
    expect(events.single.data?['length'], 3);
  });

  test('health', () async {
    final report = await callerEndpoint.health();
    expect(report.isHealthy, isTrue);
    expect(report.transportStatus?.details['zeroCopy'], isTrue);
  });
}
```

## Exercising codecs and limits over `pair()`

Same contracts, frame-encoded. A request larger than the server's
`maxMessageLengthBytes` closes the connection from the server side, so the
caller sees UNAVAILABLE; a handler-concurrency limit answers
RESOURCE_EXHAUSTED and keeps the connection.

```dart
Future<(RpcCallerEndpoint, RpcResponderEndpoint)> wire(
  RpcSecurityPolicy policy,
) async {
  final (clientTransport, serverTransport) = RpcChannelTransport.pair(
    policy: policy,
  );
  final responder = RpcResponderEndpoint(transport: serverTransport)
    ..registerServiceContract(EchoResponder())
    ..start();
  final caller = RpcCallerEndpoint(transport: clientTransport);
  addTearDown(() async {
    await caller.close();
    await responder.close();
  });
  return (caller, responder);
}

void limitTests() {
  test('codecs round-trip on the wire', () async {
    final (caller, _) = await wire(const RpcSecurityPolicy());
    expect((await EchoCaller(caller).echo(const RpcString('hi'))).value, 'hi');
  });

  test('oversized request', () async {
    final (caller, _) = await wire(
      const RpcSecurityPolicy(maxMessageLengthBytes: 1024),
    );
    await expectLater(
      EchoCaller(caller).echo(RpcString('a' * 4096)),
      throwsStatus(RpcStatus.unavailable),
    );
  });

  test('handler concurrency limit', () async {
    final (caller, _) = await wire(
      const RpcSecurityPolicy(maxConcurrentHandlers: 1),
    );
    final client = EchoCaller(caller);
    client.slow(const RpcString('x')).ignore();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await expectLater(
      client.echo(const RpcString('y')),
      throwsStatus(RpcStatus.resourceExhausted),
    );
  });
}
```

To force serialization over `memoryPair()` for one contract instead, give the
caller contract `dataTransferMode: RpcDataTransferMode.codec`; see
`codecs-and-compression.md`.

## Capturing logs

- `LogController(outputs: [RingBufferOutput(...)])`, passed as `logger:` to
  the endpoints. Read `entries`, or `query(LogFilter(minLevel: ...,
  scopes: {...}, requestId: ...))`.
- Use `minLevel: RpcLogLevel.internal` to see frame-level library logs when
  debugging a hang; set it back afterwards, it is very verbose.
- `controller.stream` is a broadcast of the same records, for
  `expectLater(controller.stream, emits(...))`.
- Inject `clock:` for deterministic timestamps.

## Pitfalls

- Only `memoryPair()` is zero-copy. `pair()` is not, and over it a method
  with no codecs on an `auto` contract throws `ArgumentError` ("Zero-copy
  requires a transport that supports zero-copy") at the caller.
- A test passing over `memoryPair()` says nothing about codecs, size limits or
  compression.
- `RpcStatusException.statusCode` is the field; there is no `code`.
- Forgetting `..start()` on the responder: the call never gets an answer.
- Forgetting to close endpoints leaks timers and stream subscriptions into
  the next test.
- An unawaited call that is expected to fail must be `.ignore()`d or
  awaited, or its error is reported as unhandled and fails the test.
- `RpcContext.withTimeout` reads the wall clock. For deterministic deadline
  logic use `context.withClock(...)`.
