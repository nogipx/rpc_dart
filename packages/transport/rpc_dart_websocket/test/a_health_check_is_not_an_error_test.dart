// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// A load balancer probes a port with a plain GET. dart:io's WebSocketTransformer
// answers such a request 400 and then completes with a `WebSocketException`,
// which `bind` forwards to its OUTPUT stream — the server's `connections` stream
// — so every probe reached `onError`: an error-level record and an
// `onConnectionError` callback, at the probe rate. Nothing downstream can tell a
// health check from a real connection failure.
//
// Both halves are asserted, because either alone is satisfiable by the wrong
// change: the noise must be gone AND the peer must still get its 400. A server
// that went quiet by no longer answering would be worse than a noisy one.
//
// The count comes from a LogController subclass, not from a filtered record
// stream: a level guard cannot be seen downstream of the filter.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:rpc_dart_websocket/src/websocket_io_connections.dart';
import 'package:test/test.dart';
import 'package:web_socket_channel/io.dart';

typedef _Run = ({int errorRecords, int onConnectionError, String peerSaw});

Future<_Run> _probeServer({
  required bool upgrade,
  int times = 10,
  Set<String>? allowedOrigins,
  String? origin,
}) async {
  final counter = _Counting();
  final http = await HttpServer.bind('127.0.0.1', 0);
  var connErrors = 0;
  final server = RpcWebSocketServer(
    connections: rpcWebSocketConnections(http, allowedOrigins: allowedOrigins),
    onEndpointCreated: (_) {},
    onConnectionError: (_, _) => connErrors++,
    logger: LogScope(counter, 'test'),
  );
  addTearDown(() async {
    await server.dispose().catchError((Object _) {});
    await http.close(force: true);
  });
  await server.start();

  var peerSaw = '?';
  for (var i = 0; i < times; i++) {
    if (upgrade) {
      try {
        final channel = IOWebSocketChannel.connect(
          Uri.parse('ws://127.0.0.1:${http.port}'),
          headers: origin == null ? null : {'origin': origin},
        );
        await channel.ready;
        peerSaw = 'upgraded';
        await channel.sink.close();
      } catch (e) {
        peerSaw = 'refused';
      }
    } else {
      final client = HttpClient();
      try {
        final req = await client.getUrl(
          Uri.parse('http://127.0.0.1:${http.port}/healthz'),
        );
        final res = await req.close();
        await res.drain<void>();
        peerSaw = '${res.statusCode}';
      } catch (e) {
        peerSaw = 'threw ${e.runtimeType}';
      }
      client.close();
    }
  }
  await Future<void>.delayed(const Duration(milliseconds: 300));

  return (
    errorRecords: counter.errors,
    onConnectionError: connErrors,
    peerSaw: peerSaw,
  );
}

void main() {
  test(
    'WITNESS: plain HTTP requests are answered without being reported as errors',
    () async {
      final run = await _probeServer(upgrade: false);

      expect(
        run.errorRecords,
        0,
        reason:
            'one error-level record per health check, at the load balancer\'s '
            'probe rate',
      );
      expect(
        run.onConnectionError,
        0,
        reason:
            'an operator callback meant for connection failures fires for every '
            'probe',
      );
      expect(
        run.peerSaw,
        '400',
        reason:
            'the noise is gone because the server stopped answering, which is a '
            'worse outcome than the noise',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // CONTROL: real handshakes must stay silent too — otherwise "0 errors" is
  // satisfied by a logger that counts nothing.
  test(
    'CONTROL: real handshakes report nothing either',
    () async {
      final run = await _probeServer(upgrade: true);

      expect(run.errorRecords, 0);
      expect(run.onConnectionError, 0);
      expect(run.peerSaw, 'upgraded');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  // GUARD: the origin gate still gates. The permitted set is now lower-cased once
  // up front rather than per handshake, and this is what says the two forms agree
  // — including the case-insensitivity the doc promises.
  group('GUARD: the origin gate is unchanged by pre-normalising it', () {
    test('a permitted origin in a different case is allowed', () async {
      final run = await _probeServer(
        upgrade: true,
        times: 1,
        allowedOrigins: {'HTTPS://App.Example.COM'},
        origin: 'https://app.example.com',
      );
      expect(run.peerSaw, 'upgraded');
    });

    test('an unlisted origin is refused', () async {
      final run = await _probeServer(
        upgrade: true,
        times: 1,
        allowedOrigins: {'https://app.example.com'},
        origin: 'https://evil.example.com',
      );
      expect(run.peerSaw, 'refused');
    });
  });
}

/// Counts error records. Done inside the controller because the guard around a
/// log call cannot be observed from the record stream — a filtered record is
/// discarded either way.
class _Counting extends LogController {
  int errors = 0;

  @override
  void add(LogRecord record) {
    if (record is LogEvent && record.level == RpcLogLevel.error) errors++;
    super.add(record);
  }
}
