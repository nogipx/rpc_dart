// SPDX-FileCopyrightText: 2026 Karim "nogipx" Mamatkazin <nogipx@gmail.com>
//
// SPDX-License-Identifier: MIT

// `connect()` attaches request headers to the upgrade and bounds the open.
//
// The upgrade REQUEST is the only place a websocket client can authenticate --
// there is no second round trip to attach a token to -- so without `headers`
// an authenticating server could not be reached through this API at all.
//
// And a peer that accepts TCP and never completes the upgrade (a firewall that
// DROPs, a balancer with no backend) is bounded by nothing else: without
// `connectTimeout` it would hold the caller until the OS gave up.
//
// The header assertions read the SERVER side: what crossed the wire, not what
// the client believes it set.
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:rpc_dart/rpc_dart.dart';
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

    // WITNESS: a token that expires must be refreshable across a reconnect.
    // RpcClientConnection calls its factory once per attempt, so a factory
    // that reads the token there presents a fresh one on every upgrade.
    test(
      'a token read in the connection factory is fresh after a reconnect',
      () async {
        final (uri, seen) = await _recordingServer();
        var issued = 0;

        final connection = RpcClientConnection(
          transportFactory: () => RpcWebSocketCallerTransport.connect(
            uri,
            headers: {'authorization': 'Bearer t${++issued}'},
          ),
        );
        addTearDown(() => connection.dispose().catchError((Object _) {}));
        Future<void> nextOnline() => connection.state
            .firstWhere((s) => s is RpcClientOnline)
            .timeout(const Duration(seconds: 10));

        final first = nextOnline();
        connection.connect();
        await first;
        final second = nextOnline();
        connection.forceReconnect();
        await second;
        await Future<void>.delayed(const Duration(milliseconds: 100));

        expect(seen, hasLength(2));
        expect(seen.first['authorization'], ['Bearer t1']);
        expect(
          seen.last['authorization'],
          ['Bearer t2'],
          reason:
              'the reconnect presented the token minted for the first upgrade',
        );
      },
    );

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
              .onError<RpcStatusException>(
                (e, _) => e.statusCode == RpcStatus.unavailable
                    ? 'bounded'
                    : 'status ${e.statusCode}',
              )
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

    // WITNESS: the DEFAULT is a bound. Waits it out, because a test bound
    // shorter than the default reads the same with and without one.
    test(
      'with no connectTimeout given, a black hole is given up on',
      () async {
        final uri = await _blackHole();

        final outcome = await RpcWebSocketCallerTransport.connect(uri)
            .then<String>((t) {
              addTearDown(() => t.close().catchError((Object _) {}));
              return 'connected to a black hole';
            })
            .onError<RpcStatusException>(
              (e, _) => e.statusCode == RpcStatus.unavailable
                  ? 'bounded'
                  : 'status ${e.statusCode}',
            )
            .timeout(
              const Duration(seconds: 40),
              onTimeout: () => 'STILL HANGING at 40 s: no default bound',
            );

        expect(outcome, 'bounded');
      },
      timeout: const Timeout(Duration(seconds: 60)),
    );

    // GUARD: the default bound leaves a healthy connect alone.
    test('GUARD: with the default bound a healthy connect works', () async {
      final (uri, _) = await _recordingServer();

      final t = await RpcWebSocketCallerTransport.connect(uri);
      addTearDown(() => t.close().catchError((Object _) {}));

      expect(t.isClosed, isFalse);
    });
  });
}
