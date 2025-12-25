// SPDX-FileCopyrightText: 2025 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_transports/rpc_dart_transports.dart';
import 'package:test/test.dart';

void main() {
  group('RpcIsolateTransport lifecycle', () {
    test('worker initiated close propagates to host', () async {
      final result = await RpcIsolateTransport.spawn(
        entrypoint: _workerClosesEntrypoint,
        customParams: const {},
        isolateId: 'lifecycle-worker-close',
      );

      final transport = result.transport;
      final status = await _waitForStatusChange(transport);

      expect(transport.isClosed, isTrue);
      expect(status.level, RpcHealthLevel.closed);
      expect(status.details['remoteExited'], isTrue);

      result.kill();
    });

    test('isolate crash closes host and updates health', () async {
      final result = await RpcIsolateTransport.spawn(
        entrypoint: _crashingEntrypoint,
        customParams: const {},
        isolateId: 'lifecycle-crash',
      );

      final transport = result.transport;
      final status = await _waitForStatusChange(transport);

      expect(transport.isClosed, isTrue);
      expect(
        status.level == RpcHealthLevel.unhealthy ||
            status.level == RpcHealthLevel.closed,
        isTrue,
        reason: 'Health should reflect isolate crash',
      );
      expect(status.details['remoteError']?.toString(), isNotNull);

      result.kill();
    });
  });
}

Future<RpcHealthStatus> _waitForStatusChange(
  IRpcTransport transport, {
  Duration timeout = const Duration(seconds: 2),
  Duration interval = const Duration(milliseconds: 50),
}) async {
  final stopwatch = Stopwatch()..start();
  var status = await transport.health();

  while (stopwatch.elapsed < timeout) {
    if (transport.isClosed) {
      return transport.health();
    }

    if (status.level == RpcHealthLevel.closed ||
        status.level == RpcHealthLevel.unhealthy) {
      return status;
    }

    await Future.delayed(interval);
    status = await transport.health();
  }

  return status;
}

void _workerClosesEntrypoint(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  Future<void>.delayed(const Duration(milliseconds: 10), () {
    unawaited(transport.close());
  });
}

void _crashingEntrypoint(
  IRpcTransport transport,
  Map<String, dynamic> params,
) {
  Future.microtask(() {
    throw StateError('worker crash');
  });
}
