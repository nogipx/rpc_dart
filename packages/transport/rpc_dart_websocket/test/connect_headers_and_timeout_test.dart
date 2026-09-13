// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `connect()` could not attach a request header and had no bound of its own.
//
//   a) via connect()                 authorization: ABSENT
//      by hand, WebSocket.connect    authorization: [Bearer t0ken]
//   b) no connectTimeout             10005ms  STILL HANGING at the probe bound
//
// The upgrade REQUEST is the only place a websocket client can authenticate --
// there is no second round trip to attach a token to -- so an authenticating
// server could not be reached through this API at all. The workaround, building
// the channel by hand, also means rebuilding the reconnect factory that carries
// the keepalive and the compression choice.
//
// And a peer that accepts TCP and never completes the upgrade (a firewall that
// DROPs, a balancer with no backend) held the caller until the OS gave up.
//
// The header assertions read the SERVER side: what crossed the wire, not what
// the client believes it set.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart_websocket/rpc_dart_websocket.dart';
import 'package:test/test.dart';

/// A server that upgrades normally and records each request's headers.
Future<(Uri, List<Map<String, List<String>>>)> _recordingServer() async {
  final seen = <Map<String, List<String>>>[];
  final server = await HttpServer.bind('127.0.0.1', 0);
  addTearDown(() => server.close(force: true));
  server.listen((req) async {
    final headers = <String, List<String>>{};
    req.headers.forEach((name, values) => headers[name] = values);
    seen.add(headers);
    final ws = await WebSocketTransformer.upgrade(req);
    ws.listen((_) {}, onError: (Object _) {}, cancelOnError: false);
  });
  return (Uri.parse('ws://${server.address.host}:${server.port}'), seen);
}

/// A peer that accepts TCP and answers nothing.
Future<Uri> _blackHole() async {
  final server = await ServerSocket.bind('127.0.0.1', 0);
  addTearDown(server.close);
  final held = <Socket>[];
  server.listen(held.add);
  addTearDown(() {
    for (final s in held) {
      s.destroy();
    }
  });
  return Uri.parse('ws://${server.address.host}:${server.port}');
}

void main() {
  group('connect() headers', () {
    // WITNESS: a token must reach the upgrade request.
    test('a header reaches the server', () async {
      final (uri, seen) = await _recordingServer();

      final t = await RpcWebSocketCallerTransport.connect(
        uri,
        headers: {'authorization': 'Bearer t0ken'},
      );
      addTearDown(() => t.close().catchError((Object _) {}));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(seen, isNotEmpty);
      expect(seen.first['authorization'], ['Bearer t0ken']);
    });

    // WITNESS: and it must survive a reconnect. A reconnect that cannot
    // authenticate is a transport that works exactly once, so carrying the
    // headers into the factory is the half that makes the feature usable.
    test('the header is sent again after a reconnect', () async {
      final (uri, seen) = await _recordingServer();

      final t = await RpcWebSocketCallerTransport.connect(
        uri,
        headers: {'authorization': 'Bearer t0ken'},
      );
      addTearDown(() => t.close().catchError((Object _) {}));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await t.reconnect();
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(seen, hasLength(greaterThanOrEqualTo(2)));
      expect(
        seen.last['authorization'],
        ['Bearer t0ken'],
        reason: 'the token went only on the first upgrade',
      );
    });

    // GUARD: no headers must stay no headers -- the control the witnesses are
    // read against, and proof the assertion is not passing on some default.
    test('GUARD: without headers none is sent', () async {
      final (uri, seen) = await _recordingServer();

      final t = await RpcWebSocketCallerTransport.connect(uri);
      addTearDown(() => t.close().catchError((Object _) {}));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(seen, isNotEmpty);
      expect(seen.first['authorization'], isNull);
    });
  });

  group('connect() timeout', () {
    // WITNESS: the open must be bounded when a bound is asked for.
    //
    // Raced against a probe bound rather than simply awaited, so an unbounded
    // connect fails with a REAL message in 3 s instead of hanging into the test
    // runner's 30 s timeout -- which reports nothing about what went wrong.
    test('a black hole is given up on', () async {
      final uri = await _blackHole();

      final outcome =
          await RpcWebSocketCallerTransport.connect(
                uri,
                connectTimeout: const Duration(milliseconds: 600),
              )
              .then<String>((t) {
                addTearDown(() => t.close().catchError((Object _) {}));
                return 'connected to a black hole';
              })
              .onError<TimeoutException>((_, _) => 'bounded')
              .timeout(
                const Duration(seconds: 3),
                onTimeout: () =>
                    'STILL HANGING: connectTimeout was not applied',
              );

      expect(outcome, 'bounded');
    });

    // GUARD: a healthy server must not be timed out. A bound that always fires
    // would pass the witness and break every connection.
    test('GUARD: a reachable server connects well inside the bound', () async {
      final (uri, _) = await _recordingServer();

      final t = await RpcWebSocketCallerTransport.connect(
        uri,
        connectTimeout: const Duration(seconds: 5),
      );
      addTearDown(() => t.close().catchError((Object _) {}));

      expect(t.isClosed, isFalse);
    });

    // GUARD: null is still the default and still unbounded, so nobody's
    // existing behaviour changed under them.
    test('GUARD: without a bound a healthy connect still works', () async {
      final (uri, _) = await _recordingServer();

      final t = await RpcWebSocketCallerTransport.connect(uri);
      addTearDown(() => t.close().catchError((Object _) {}));

      expect(t.isClosed, isFalse);
    });
  });
}
