<!--
SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>

SPDX-License-Identifier: MIT
-->

# Testing & tooling

Testing RPC services should be as frictionless as testing regular functions.
RPC Dart exposes utilities and patterns that make it simple to exercise
contracts, transports, and streaming logic in isolation or end-to-end.

## In-memory end-to-end tests

`RpcInMemoryTransport.pair()` produces a connected client/server transport with
zero serialisation overhead. It is the quickest way to run integration tests.

```dart
final (clientTransport, serverTransport) = RpcInMemoryTransport.pair();

final responder = RpcResponderEndpoint(transport: serverTransport)
  ..registerServiceContract(CalculatorResponder())
  ..start();

final caller = RpcCallerEndpoint(transport: clientTransport);
final calculator = CalculatorCaller(caller);

expect(await calculator.add(AddRequest(1, 2)), isA<AddResponse>());
```

Because data is passed by reference you can assert on complex object identity or
mutations without dealing with serialisation noise.

## Controlling context during tests

`RpcContextBuilder` helps you craft trace IDs, deadlines, and metadata for your
scenarios:

```dart
final ctx = RpcContextBuilder()
    .withHeader('x-test-case', 'retry-path')
    .withTimeout(const Duration(milliseconds: 200))
    .build();

await calculator.add(AddRequest(1, 2), context: ctx);
```

Use `RpcContext.sanitize` before snapshotting contexts in golden tests to strip
sensitive headers such as API keys.

## Inspecting transport state

Expose `RpcEndpointHealth` in assertions to guarantee transports remain healthy
throughout the test:

```dart
final report = await caller.health();
expect(report.endpointStatus.level, RpcHealthLevel.healthy);
expect(report.transportStatus?.details['activeStreams'], equals(0));
```

Pair this with `caller.ping()` when you need deterministic latency expectations
or to verify that routers point to the right downstream service.

## Testing streaming behaviour

Streams are first-class citizens in the testing story. Use `expectLater` with the
Dart `Stream` API to assert on emitted events, errors, and completion:

```dart
final updates = chat.joinRoom('general', 'u-1');
expectLater(
  updates,
  emitsInOrder([
    predicate<ChatMessage>((m) => m.type == MessageType.joined),
    emitsDone,
  ]),
);
```

`StreamDistributor` provides metrics that you can assert against to confirm that
cleanup logic works as expected:

```dart
final distributor = StreamDistributor<ChatMessage>();
final stream = distributor.createClientStreamWithId('test');
final subscription = stream.listen((_) {});

distributor.publish(ChatMessage('hello'));
expect(distributor.metrics.totalMessages, 1);
await subscription.cancel();
```

## Faking transports

When you need to simulate edge cases (packet loss, reconnects, buffering),
implement `IRpcTransport` in tests. Keeping the transport fake in-memory makes
it easy to deterministically trigger failure modes.

```dart
import 'dart:async';
import 'dart:typed_data';

import 'package:rpc_dart/rpc_dart.dart';

class FlakyTransport implements IRpcTransport {
  final _incoming = StreamController<RpcTransportMessage>.broadcast();
  final _ids = RpcStreamIdManager(isClient: true);
  var _closed = false;

  bool dropNextMessage = false;

  @override
  bool get isClient => true;

  @override
  bool get isClosed => _closed;

  @override
  bool get supportsZeroCopy => false;

  @override
  Stream<RpcTransportMessage> get incomingMessages => _incoming.stream;

  @override
  Stream<RpcTransportMessage> getMessagesForStream(int streamId) =>
      incomingMessages.where((m) => m.streamId == streamId);

  @override
  int createStream() => _ids.generateId();

  @override
  bool releaseStreamId(int streamId) => _ids.releaseId(streamId);

  @override
  Future<void> sendMetadata(
    int streamId,
    RpcMetadata metadata, {
    bool endStream = false,
  }) async {}

  @override
  Future<void> sendMessage(
    int streamId,
    Uint8List data, {
    bool endStream = false,
  }) async {
    if (dropNextMessage) {
      dropNextMessage = false;
      return;
    }

    _incoming.add(
      RpcTransportMessage(
        streamId: streamId,
        payload: data,
        isEndOfStream: endStream,
      ),
    );
  }

  @override
  Future<void> sendDirectObject(
    int streamId,
    Object object, {
    bool endStream = false,
  }) async {
    throw UnsupportedError('Zero-copy is disabled in this transport');
  }

  @override
  Future<void> finishSending(int streamId) async {}

  @override
  Future<RpcHealthStatus> health() async => RpcHealthStatus.healthy(
        component: runtimeType.toString(),
        message: 'OK',
        details: {'isClosed': _closed},
      );

  @override
  Future<RpcHealthStatus> reconnect() async => RpcHealthStatus.degraded(
        component: runtimeType.toString(),
        message: 'Reconnect is not implemented for this fake transport',
        details: {'supported': false},
      );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _incoming.close();
  }
}
```

Combine flaky transports with real endpoints to exercise retry logic and error
handling paths.

## Leveraging logging in tests

Inject a custom logger via `RpcLogger.setLoggerFactory` that records messages in
memory. This lets you assert on emitted diagnostics without relying on stdout.

```dart
final events = <String>[];
RpcLogger.setLoggerFactory((name, {colors, label, context}) {
  return InMemoryLogger(name, onLog: events.add);
});
```

## Automation tips

- Add a `just` recipe or `dart test --platform vm` command to CI that runs your
  suites with `--run-skipped` to surface quarantined tests early.
- Run `dart run benchmark/benchmark.dart` inside `packages/rpc_dart` to
  stress-test zero-copy code paths and compare codec performance.
- Capture `RpcContext` snapshots on failure to speed up debugging of distributed
  workflows.

With these patterns your RPC services stay easy to verify, refactor, and extend
as new requirements arrive.
