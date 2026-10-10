// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A failed `connect` throws an RpcStatusException, as the http caller reports
// the same failures, so a `shouldReconnect` can tell a refusal on identity
// (401, 403) from an outage.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

/// Connects to [port] and returns the failure as `status N`, or its type.
Future<String> _failureOf(
  int port, {
  Duration connectTimeout = const Duration(seconds: 5),
  FutureOr<Map<String, Object>> Function()? headersProvider,
}) async {
  try {
    final t = await RpcWebSocketCallerTransport.connect(
      Uri.parse('ws://127.0.0.1:$port/'),
      connectTimeout: connectTimeout,
      headersProvider: headersProvider,
    );
    await t.close();
    return 'connected';
  } on RpcStatusException catch (e) {
    return 'status ${e.statusCode}';
  } catch (e) {
    return '${e.runtimeType}';
  }
}

Future<int> _answering(int status) async {
  final s = await HttpServer.bind('127.0.0.1', 0);
  addTearDown(() => s.close(force: true));
  s.listen((r) async {
    await r.drain<void>();
    r.response.statusCode = status;
    await r.response.close();
  });
  return s.port;
}

void main() {
  for (final (http, grpc) in [
    (401, RpcStatus.unauthenticated),
    (403, RpcStatus.permissionDenied),
    (404, RpcStatus.unimplemented),
    (503, RpcStatus.unavailable),
  ]) {
    test('WITNESS: an upgrade answered $http is status $grpc', () async {
      expect(await _failureOf(await _answering(http)), 'status $grpc');
    });
  }

  test(
    'WITNESS: the server gate refusing the upgrade is PERMISSION_DENIED',
    () async {
      final io = await HttpServer.bind('127.0.0.1', 0);
      final server = RpcWebSocketServer(
        connections: rpcWebSocketConnections(io, allowUpgrade: (_) => false),
        onEndpointCreated: (_) {},
      );
      await server.start();
      addTearDown(() async {
        await server.stop();
        await io.close(force: true);
      });

      expect(await _failureOf(io.port), 'status ${RpcStatus.permissionDenied}');
    },
  );

  test(
    'WITNESS: a connection closed during the upgrade is UNAVAILABLE',
    () async {
      final closer = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(closer.close);
      closer.listen((s) => s.listen((_) => s.destroy()));

      expect(await _failureOf(closer.port), 'status ${RpcStatus.unavailable}');
    },
  );

  test('WITNESS: connectTimeout is UNAVAILABLE', () async {
    final silent = await ServerSocket.bind('127.0.0.1', 0);
    final held = <Socket>[];
    addTearDown(() async {
      for (final s in held) {
        s.destroy();
      }
      await silent.close();
    });
    silent.listen(held.add);

    expect(
      await _failureOf(
        silent.port,
        connectTimeout: const Duration(milliseconds: 300),
      ),
      'status ${RpcStatus.unavailable}',
    );
  });

  // dart:io writes the whole uri into its errors, and the query is where a web
  // client puts its token.
  test('WITNESS: the message carries no userinfo and no query', () async {
    final closer = await ServerSocket.bind('127.0.0.1', 0);
    addTearDown(closer.close);
    closer.listen((s) => s.listen((_) => s.destroy()));

    Object? error;
    try {
      await RpcWebSocketCallerTransport.connect(
        Uri.parse(
          'ws://user:pw-secret@127.0.0.1:${closer.port}/rpc?token=q-secret',
        ),
      );
    } catch (e) {
      error = e;
    }

    expect(error, isA<RpcStatusException>());
    expect('$error', isNot(contains('pw-secret')));
    expect('$error', isNot(contains('q-secret')));
    expect('$error', contains('127.0.0.1'), reason: 'the address stays');
  });

  test('GUARD: an exception from headersProvider is not rewritten', () async {
    expect(
      await _failureOf(
        await _answering(401),
        headersProvider: () => throw const FormatException('token store'),
      ),
      'FormatException',
    );
  });
}
