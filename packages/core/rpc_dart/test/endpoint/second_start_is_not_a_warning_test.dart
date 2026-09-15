// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// Starting a responder twice is ORDINARY: `RpcWebSocketServer` calls
// `onEndpointCreated` and then `endpoint.start()`, while the framework's
// callback registers the contracts and starts it too. Both run per connection,
// so the second call warned every time — 704 and 698 warnings in 24 h on a
// consumer's two replicas, against 6 and 34 lines of real error.
//
// The redundant call is now internal-level. A second call asking for a
// DIFFERENT messageFilter still warns, because that one is a real mistake: the
// first filter stays in effect and the caller silently does not get the
// filtering it asked for.

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:test/test.dart';

/// Collects what the endpoint logs, at every level.
class _Capture implements LogOutput {
  final records = <LogEvent>[];

  @override
  String? get scopeFilter => null;

  @override
  void write(LogRecord record) {
    if (record is LogEvent) records.add(record);
  }

  @override
  Future<void> writeAsync(LogRecord record) async => write(record);

  @override
  bool get isAsync => false;

  @override
  void dispose() {}

  List<String> get warnings => [
    for (final r in records)
      if (r.level == RpcLogLevel.warning) r.message,
  ];
}

void main() {
  late _Capture capture;
  late LogController logs;
  late RpcChannelTransport client;
  late RpcChannelTransport server;
  late RpcResponderEndpoint endpoint;

  setUp(() {
    capture = _Capture();
    logs = LogController(outputs: [capture], minLevel: RpcLogLevel.internal);
    final pair = RpcChannelTransport.pair();
    client = pair.$1;
    server = pair.$2;
    endpoint = RpcResponderEndpoint(transport: server, logger: logs);
  });

  tearDown(() async {
    await endpoint.close();
    await client.close();
    await server.close();
  });

  test('the ordinary second start does not warn', () async {
    endpoint.start();
    endpoint.start();
    await Future<void>.delayed(Duration.zero);

    expect(
      capture.warnings.where((m) => m.contains('Already listening')),
      isEmpty,
      reason: 'a redundant start is how the server and the framework compose',
    );
  });

  test('a second start with a different filter still warns', () async {
    await endpoint.startResponderListening(messageFilter: (_) => true);
    await endpoint.startResponderListening(messageFilter: (_) => false);

    expect(
      capture.warnings.where((m) => m.contains('different messageFilter')),
      hasLength(1),
      reason: 'the first filter stays, so the second caller must be told',
    );
  });

  test('GUARD: the endpoint still serves after a redundant start', () async {
    endpoint.registerServiceContract(_EchoContract());
    endpoint.start();
    endpoint.start();

    final caller = RpcCallerEndpoint(transport: client);
    final answer = await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'ping'.rpc,
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
        )
        .timeout(const Duration(seconds: 5));

    expect(answer.value, 'ping');
    await caller.close();
  });

  test('GUARD: a redundant start does not double-deliver', () async {
    var handlerCalls = 0;
    endpoint.registerServiceContract(
      _EchoContract(onCall: () => handlerCalls++),
    );
    endpoint.start();
    endpoint.start();

    final caller = RpcCallerEndpoint(transport: client);
    await caller
        .unaryRequest<RpcString, RpcString>(
          serviceName: 'Svc',
          methodName: 'echo',
          request: 'ping'.rpc,
          requestCodec: RpcString.codec,
          responseCodec: RpcString.codec,
        )
        .timeout(const Duration(seconds: 5));

    expect(handlerCalls, 1, reason: 'two subscriptions would run it twice');
    await caller.close();
  });
}

final class _EchoContract extends RpcResponderContract {
  _EchoContract({this.onCall}) : super('Svc');
  final void Function()? onCall;

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'echo',
      handler: (request, {RpcContext? context}) async {
        onCall?.call();
        return request;
      },
      requestCodec: RpcString.codec,
      responseCodec: RpcString.codec,
    );
  }
}
