// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// The refusal path drained the request body with no deadline.
//
// `_refuse` must drain before answering -- dart:io tears the connection down
// before the status is flushed otherwise -- and the drain was unbounded. It is
// also `unawaited`, so the accept loop takes the next connection immediately
// and any number of these run at once, counted by nothing.
//
// Measured, 16 sockets promising a body and sending five bytes, against a
// server with an `allowedOrigins` allowlist, window 12s:
//
//   plain POST, refused, unbounded :  0 of 16 answered, all draining
//   plain POST, refused, bounded   : 16 of 16, connection cut at the budget
//   upgrade-shaped, refused        : 16 of 16 answered 403 -- dart:io hands a
//                                    CONNECTION-UPGRADE request no body at all
//
// The path exists ONLY when allowedOrigins or allowUpgrade is configured, so it
// is reachable exactly on the servers that turned the origin check on. Same
// defect as rpc_dart_http's `_reject`, fixed one round earlier.

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_websocket/io.dart';
import 'package:test/test.dart';

const int _sockets = 8;

/// Must exceed the library's `_refusalDrainBudget`, or the fix reads as absent.
const Duration _window = Duration(seconds: 12);

const String _allowed = 'https://allowed.example';
const String _rejected = 'https://evil.example';

Future<int> _serve({required void Function() onUpgrade}) async {
  final http = await HttpServer.bind('127.0.0.1', 0);
  rpcWebSocketConnections(
    http,
    allowedOrigins: const {_allowed},
  ).listen((_) => onUpgrade());
  addTearDown(() => http.close(force: true));
  return http.port;
}

/// Opens a request that promises a body and sends almost none, then holds the
/// connection. Completes on the server's first byte, or on close.
Future<String> _slowBody(
  int port,
  String origin, {
  required bool upgrade,
}) async {
  final socket = await Socket.connect('127.0.0.1', port);
  final settled = Completer<String>();
  void finish(String how) {
    if (!settled.isCompleted) settled.complete(how);
  }

  socket.listen(
    (bytes) => finish(String.fromCharCodes(bytes).split('\r\n').first),
    onDone: () => finish('closed'),
    onError: (_) => finish('closed'),
  );
  socket.write(
    upgrade
        ? 'GET / HTTP/1.1\r\n'
              'host: 127.0.0.1:$port\r\n'
              'upgrade: websocket\r\n'
              'connection: Upgrade\r\n'
              'sec-websocket-version: 13\r\n'
              'sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
              'origin: $origin\r\n'
              'content-length: 100000\r\n'
              '\r\n'
        : 'POST / HTTP/1.1\r\n'
              'host: 127.0.0.1:$port\r\n'
              'origin: $origin\r\n'
              'content-length: 100000\r\n'
              '\r\n',
  );
  socket.add(const <int>[1, 2, 3, 4, 5]);
  await socket.flush();
  addTearDown(socket.destroy);
  return settled.future;
}

Future<List<String>> _settleAll(List<Future<String>> attacks) => Future.wait(
  attacks.map((f) => f.timeout(_window, onTimeout: () => 'STILL DRAINING')),
);

void main() {
  test(
    'a refused request with a body that never arrives is let go',
    () async {
      // WITNESS. Pre-fix all 8 read STILL DRAINING, at any window.
      final port = await _serve(onUpgrade: () {});

      final settled = await _settleAll([
        for (var i = 0; i < _sockets; i++)
          _slowBody(port, _rejected, upgrade: false),
      ]);

      expect(
        settled.where((s) => s == 'STILL DRAINING'),
        isEmpty,
        reason: 'the refusal drain must have a deadline',
      );
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: a permitted origin still upgrades',
    () async {
      // Without this the witness would pass on a server that refused everything.
      var upgraded = 0;
      final port = await _serve(onUpgrade: () => upgraded++);

      final settled = await _settleAll([
        for (var i = 0; i < _sockets; i++)
          _slowBody(port, _allowed, upgrade: true),
      ]);

      expect(settled, everyElement(contains('101')));
      expect(upgraded, _sockets);
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test(
    'GUARD: a refused upgrade still gets its 403',
    () async {
      // The bound must not cost an ordinary refusal its status. dart:io gives a
      // connection-upgrade request no body, so this one drains instantly.
      final port = await _serve(onUpgrade: () {});

      final settled = await _settleAll([
        for (var i = 0; i < _sockets; i++)
          _slowBody(port, _rejected, upgrade: true),
      ]);

      expect(settled, everyElement(contains('403')));
    },
    timeout: const Timeout(Duration(seconds: 90)),
  );
}
