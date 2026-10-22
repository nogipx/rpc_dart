// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The frame guard in rpcWebSocketConnections refuses a message past the
// largest one the policy admits. That policy is the SERVER's: a limit raised on
// RpcWebSocketServer alone must raise the guard's ceiling too, or a message
// between the two is refused as a broken connection and retried forever.
//
// The hand-off needs the stream the function returned. A wrapped one cannot
// carry it, so there the server warns instead.

@TestOn('vm')
library;

import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

final _codec = RpcCodec(RpcString.fromJson);

final class _Echo extends RpcResponderContract {
  _Echo() : super('Svc');

  @override
  void setup() {
    addUnaryMethod<RpcString, RpcString>(
      methodName: 'length',
      handler: (request, {RpcContext? context}) async =>
          '${request.value.length}'.rpc,
      requestCodec: _codec,
      responseCodec: _codec,
    );
  }
}

const _raised = RpcSecurityPolicy(maxMessageLengthBytes: 32 * 1024 * 1024);
const _size = 20 * 1024 * 1024;

Future<String> _send({
  RpcSecurityPolicy? connectionsPolicy,
  bool wrapped = false,
}) async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  final connections = rpcWebSocketConnections(http, policy: connectionsPolicy);
  final server = RpcWebSocketServer(
    connections: wrapped ? connections.where((_) => true) : connections,
    policy: _raised,
    mode: RpcResponderMode(
      (endpoint) => endpoint.registerServiceContract(_Echo()),
    ),
  );
  await server.start();
  addTearDown(() async {
    await server.stop();
    await http.close(force: true);
  });

  final client = await RpcWebSocketCallerTransport.connect(
    Uri.parse('ws://127.0.0.1:${http.port}'),
    policy: _raised,
  );
  final caller = RpcCallerEndpoint(transport: client);
  addTearDown(() async {
    await caller.close();
    await client.close();
  });
  final answer = await caller
      .unary<RpcString, RpcString>(
        serviceName: 'Svc',
        methodName: 'length',
        request: ('a' * _size).rpc,
        requestCodec: _codec,
        responseCodec: _codec,
      )
      .timeout(const Duration(seconds: 20));
  return answer.value;
}

/// The warnings a server logs over two starts with [policy].
Future<List<String>> _startWarnings({
  required bool wrapped,
  required RpcSecurityPolicy policy,
}) async {
  final recorder = _Warnings();
  final http = await HttpServer.bind('127.0.0.1', 0);
  final connections = rpcWebSocketConnections(http);
  final server = RpcWebSocketServer(
    connections: wrapped ? connections.where((_) => true) : connections,
    policy: policy,
    logger: LogScope(recorder, 'test'),
    mode: RpcResponderMode(
      (endpoint) => endpoint.registerServiceContract(_Echo()),
    ),
  );
  addTearDown(() async {
    await server.dispose();
    await http.close(force: true);
  });
  await server.start();
  await server.stop();
  await server.start();
  return recorder.warnings;
}

final class _Warnings extends LogController {
  final List<String> warnings = [];

  @override
  void add(LogRecord record) {
    if (record is LogEvent && record.level == RpcLogLevel.warning) {
      warnings.add(record.message);
    }
    super.add(record);
  }
}

void main() {
  test(
    'a limit raised on the server alone admits the larger message',
    () async {
      expect(await _send(), '$_size');
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );

  // A stream wrapped with `.where` or `.map` is a plain Stream, and the
  // server's policy cannot follow it to the guard: the larger message is
  // dropped as a broken connection. The server says so once, at start, with
  // what to do instead.
  group('a wrapped connections stream', () {
    test(
      'WITNESS: the larger message is still dropped',
      () async {
        await expectLater(
          _send(wrapped: true),
          throwsA(
            isA<RpcStatusException>().having(
              (e) => e.statusCode,
              'status',
              RpcStatus.unavailable,
            ),
          ),
        );
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );

    // Once over two starts: a restart reuses the kept subscription.
    test('WITNESS: a raised limit is warned about once', () async {
      final warnings = await _startWarnings(wrapped: true, policy: _raised);
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('pass `policy:`'));
      expect(warnings.single, contains('allowUpgrade'));
    });

    test('GUARD: the default limit loses nothing and is not warned', () async {
      expect(
        await _startWarnings(wrapped: true, policy: const RpcSecurityPolicy()),
        isEmpty,
      );
    });

    test('GUARD: an unwrapped stream is not warned', () async {
      expect(await _startWarnings(wrapped: false, policy: _raised), isEmpty);
    });
  });

  test(
    'CONTROL the same policy passed to the connections too',
    () async {
      expect(await _send(connectionsPolicy: _raised), '$_size');
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}
