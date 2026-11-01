// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// WebSocket is not subject to the same-origin policy, so an ungated server
// upgrades ANY origin — a browser page can open a socket and ride ambient
// credentials (CSWSH). The gate (allowedOrigins / allowUpgrade) is opt-in
// and cannot be defaulted, because the origins are the application's to know;
// what the library can do is make an ungated deployment a VISIBLE choice.
// That is the one-time warning this file pins: exactly one per process, to
// the given logger, and none at all when a gate is configured.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/io.dart';
import 'package:test/test.dart';

void main() {
  test('an ungated server warns once; a gated one does not', () async {
    final controller = LogController();
    addTearDown(controller.dispose);
    final warnings = <String>[];
    final sub = controller.stream.listen((record) {
      if (record is LogEvent && record.level == RpcLogLevel.warning) {
        warnings.add(record.message);
      }
    });
    addTearDown(sub.cancel);

    Future<int> serve({
      Set<String>? allowedOrigins,
      bool Function(HttpRequest request)? allowUpgrade,
    }) async {
      final http = await HttpServer.bind('127.0.0.1', 0);
      rpcWebSocketConnections(
        http,
        allowedOrigins: allowedOrigins,
        allowUpgrade: allowUpgrade,
        logger: LogScope(controller, 'test'),
      ).listen((_) {});
      addTearDown(() => http.close(force: true));
      return http.port;
    }

    await serve();
    // Records travel a broadcast stream: delivered in a later microtask than
    // the synchronous warning call, so let the queue drain before counting.
    await pumpEventQueue();
    expect(warnings, hasLength(1), reason: 'the first ungated server warns');
    expect(warnings.single, contains('allowedOrigins'));

    await serve();
    await pumpEventQueue();
    expect(
      warnings,
      hasLength(1),
      reason: 'the warning is once per process, not once per server',
    );

    await serve(allowedOrigins: const {'https://app.example'});
    await serve(allowUpgrade: (_) => true);
    await pumpEventQueue();
    expect(
      warnings,
      hasLength(1),
      reason: 'configuring either gate silences the warning entirely',
    );
  });
}
